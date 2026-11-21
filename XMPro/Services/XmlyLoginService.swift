
import Foundation

typealias PassportResponse = (statusCode: Int, body: String)

protocol PassportTransport {
    /// 一次应用层往返；实现不得主动重试 POST。
    func roundTrip(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> PassportResponse
}

final class URLSessionPassportTransport: PassportTransport {
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private let redirectDelegate = RedirectDelegate()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // URLSession 没有独立 connect/read/write timeout：
        // request 为无数据等待超时，resource 为整个资源的总超时。
        // TODO(Mac)：确认这两个近似值满足产品要求；不是精确的 10/25/25。
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func roundTrip(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> PassportResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (bytes, response) = try await session.bytes(
            for: request, delegate: redirectDelegate
        )
        defer { bytes.task.cancel() }

        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // 最多保留 limit + 1 字节。超限由服务层统一转换为 XmlyError；
        // 这里不把解析或业务错误伪装成传输失败。
        let limit = 512 * 1024
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit {
                return (
                    response.statusCode,
                    String(repeating: "x", count: limit + 1)
                )
            }
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return (response.statusCode, text)
    }
}

actor XmlyLoginService {
    private final class Pending {
        let id: String
        let encryptedMobile: String
        let deviceId: String
        let expiresAt: Int64
        var attempts = 0

        init(
            id: String,
            encryptedMobile: String,
            deviceId: String,
            expiresAt: Int64
        ) {
            self.id = id
            self.encryptedMobile = encryptedMobile
            self.deviceId = deviceId
            self.expiresAt = expiresAt
        }
    }

    private let transport: any PassportTransport
    private let clock: ServerClock
    private let deviceId: String
    private var generation: UInt64 = 0
    private var pending: Pending?
    private var usedLots: [String: Int64] = [:]
    private var lastSms: [String: Int64] = [:]

    // actor 在 await 时可重入。此门闩串行化完整登录操作；
    // clear 不取门闩，能立即使正在等待网络的操作失效。
    // 等待者队列见文件末尾 acquire() 附近的 Waiter 状态机。
    private var busy = false

    init(
        transport: any PassportTransport,
        clock: ServerClock = .shared,
        deviceOverride: String? = nil
    ) {
        self.transport = transport
        self.clock = clock
        if let deviceOverride,
           !deviceOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deviceId = deviceOverride
        } else {
            deviceId = UUID().uuidString.lowercased()
        }
    }

    nonisolated func config() -> [String: Any] {
        [
            "captcha_id": ProtocolConfig.captchaID,
            "biz": 1,
            "captcha_fields": ProtocolConfig.geeTestFields.sorted()
        ]
    }

    nonisolated static func signature(values: [String: String]) -> String {
        // S1 已实现相同 salt、排序、整体 uppercase 和 SHA-1。
        Signatures.login(values)
    }

    func clear() {
        generation &+= 1
        pending = nil
    }

    func sendSms(
        mobile: String,
        geetest: [String: String],
        device: String = ""
    ) async throws -> String {
        guard ProtocolBytes.fullMatch(#"^\+?[0-9]{6,18}$"#, mobile) else {
            throw B1JSON.error(.invalidMobile, definitive: true)
        }
        for field in ProtocolConfig.geeTestFields {
            guard let value = geetest[field],
                  ProtocolBytes.fullMatch(#"^[\x21-\x7e]{1,8192}$"#, value) else {
                throw B1JSON.error(.invalidCaptcha, definitive: true)
            }
        }
        guard geetest["captcha_id"]?.lowercased()
                == ProtocolConfig.captchaID.lowercased() else {
            throw B1JSON.error(.invalidCaptcha, definitive: true)
        }
        try validateDevice(device)
        let target = device.isEmpty ? deviceId : device
        // 也检查注入的默认设备，避免通过 deviceOverride 绕过 Cookie 校验。
        try validateDevice(target)
        // Credentials 的设备字符集比登录 Cookie 更严格；发送前即拒绝，
        // 避免走完短信+验证+登录才在构造凭据时失败、且 challenge 已消耗。
        guard Credentials.isValidDeviceId(target) else {
            throw B1JSON.error(.invalidDevice, definitive: true)
        }

        let requestedGeneration = generation
        try await acquire()
        defer { release() }
        try checkGeneration(requestedGeneration)

        let now = clock.now()
        usedLots = usedLots.filter { !elapsed(now, since: $0.value, limit: 600_000) }
        lastSms = lastSms.filter { !elapsed(now, since: $0.value, limit: 180_000) }

        let lot = ProtocolBytes.sha256Hex(geetest["lot_number"]!)
        let phone = ProtocolBytes.sha256Hex(
            mobile.hasPrefix("+") ? String(mobile.dropFirst()) : mobile
        )
        guard usedLots[lot] == nil else {
            throw B1JSON.error(.captchaReused, definitive: true)
        }
        guard lastSms[phone] == nil else {
            throw B1JSON.error(.smsCooldown, definitive: true)
        }

        // 未知网络结果也消耗 lot 和冷却窗口，不允许自动重发短信。
        usedLots[lot] = now
        lastSms[phone] = now
        pending = nil

        let encrypted = try Signatures.encryptMobile(mobile)
        let nonceValue = try await nonce(
            device: target, generation: requestedGeneration
        )
        try checkGeneration(requestedGeneration)
        let fields = Dictionary(uniqueKeysWithValues:
            ProtocolConfig.geeTestFields.map { ($0, geetest[$0]!) }
        )
        _ = try await post(
            path: "mobile/sms/v3/send",
            device: target,
            values: [
                "mobile": encrypted,
                "sendType": "1",
                "biz": "1",
                "nonce": nonceValue,
                "fdsOtp": try B1JSON.encode(fields)
            ],
            rejection: .smsSendRejected,
            generation: requestedGeneration
        )
        try checkGeneration(requestedGeneration)

        let id = ProtocolBytes.newNonce()
        let expiration = now.addingReportingOverflow(600_000)
        pending = Pending(
            id: id,
            encryptedMobile: encrypted,
            deviceId: target,
            expiresAt: expiration.overflow ? Int64.max : expiration.partialValue
        )
        return id
    }

    func verifySms(challengeId: String, code: String) async throws -> LoginResult {
        guard ProtocolBytes.fullMatch(#"^[A-Za-z0-9_-]{1,128}$"#, challengeId) else {
            throw B1JSON.error(.challengeInvalid, definitive: true)
        }
        guard ProtocolBytes.fullMatch(#"^[0-9]{4,8}$"#, code) else {
            throw B1JSON.error(.invalidCode, definitive: true)
        }

        let requestedGeneration = generation
        try await acquire()
        defer { release() }
        try checkGeneration(requestedGeneration)
        guard let active = pending, active.id == challengeId else {
            throw B1JSON.error(.challengeInvalid, definitive: true)
        }
        try checkActive(active)
        defer {
            active.attempts += 1
            if active.attempts >= 5, pending === active {
                pending = nil
            }
        }

        let verifyNonce = try await nonce(
            device: active.deviceId,
            generation: requestedGeneration,
            active: active
        )
        let verified = try await post(
            path: "mobile/sms/v2/verify",
            device: active.deviceId,
            values: [
                "mobile": active.encryptedMobile,
                "code": code,
                "nonce": verifyNonce
            ],
            rejection: .smsVerifyRejected,
            generation: requestedGeneration,
            active: active
        )

        let rawKey = Self.fallback(verified["bizKey"], to: verified["smsKey"])
        guard let key = rawKey as? String,
              !key.isEmpty, key.utf16.count <= 8192 else {
            throw B1JSON.error(.invalidResponse)
        }

        let loginNonce = try await nonce(
            device: active.deviceId,
            generation: requestedGeneration,
            active: active
        )
        let login = try await post(
            path: "mobile/login/quick/v2",
            device: active.deviceId,
            values: [
                "mobile": active.encryptedMobile,
                "smsKey": key,
                "nonce": loginNonce
            ],
            rejection: .quickLoginRejected,
            generation: requestedGeneration,
            active: active
        )
        try checkActive(active)
        let nested = login["data"] as? [String: Any]
        let uid = B1JSON.text(Self.fallback(login["uid"], to: nested?["uid"]))
        let token = Self.fallback(login["token"], to: nested?["token"]) as? String

        guard ProtocolBytes.fullMatch(#"^[1-9][0-9]{0,19}$"#, uid),
              let token,
              ProtocolBytes.fullMatch(#"^[A-Za-z0-9._~+/=\-]{1,8192}$"#, token) else {
            throw B1JSON.error(.invalidResponse)
        }

        // Kotlin 在此消费 challenge：字段校验通过后、构造凭据前清除 pending，
        // 使凭据构造失败也不留可复用的 challenge。
        pending = nil
        // Credentials 的设备字符集比 Kotlin 登录 Cookie 更严格。
        // 保留现有凭据模型校验，不偷偷修改设备或替换账号身份。
        let credentials = try Credentials(
            token: uid + "&" + token, deviceId: active.deviceId
        )
        let avatar = Self.findString(
            root: login, keys: ["avatar", "avatarUrl", "logoPic", "smallLogo"]
        )
        let result = LoginResult(
            credentials: credentials,
            nickname: Self.findString(
                root: login, keys: ["nickname", "userName", "nickName"]
            ) ?? "",
            avatarUrl: avatar,
            mobile: Self.findString(
                root: login, keys: ["mobile", "phone", "mobilePhone"]
            ) ?? ""
        )
        return result
    }

    private func validateDevice(_ device: String) throws {
        guard device.utf16.count <= 128,
              device.unicodeScalars.allSatisfy({
                  $0.value > 32 && $0.value < 127
                      && !";&,\"\\".unicodeScalars.contains($0)
              }) else {
            throw B1JSON.error(.invalidDevice, definitive: true)
        }
    }

    private func elapsed(_ now: Int64, since: Int64, limit: Int64) -> Bool {
        guard now >= since else { return false }
        let delta = now.subtractingReportingOverflow(since)
        return delta.overflow || delta.partialValue >= limit
    }

    private func checkGeneration(_ value: UInt64) throws {
        guard generation == value else {
            throw B1JSON.error(.challengeInvalid, definitive: true)
        }
        try Task.checkCancellation()
    }

    private func checkActive(_ value: Pending) throws {
        guard pending === value else {
            throw B1JSON.error(.challengeInvalid, definitive: true)
        }
        guard clock.now() < value.expiresAt else {
            pending = nil
            throw B1JSON.error(.challengeExpired, definitive: true)
        }
    }

    private func checkState(generation: UInt64, active: Pending?) throws {
        try checkGeneration(generation)
        if let active { try checkActive(active) }
    }

    private func nonce(
        device: String,
        generation: UInt64,
        active: Pending? = nil
    ) async throws -> String {
        let result = try await request(
            method: "GET",
            path: "mobile/nonce/\(clock.now())",
            device: device,
            body: nil,
            generation: generation,
            active: active
        )
        if result["ret"] != nil {
            try check(result, rejection: .nonceRejected)
        }
        guard let value = result["nonce"] as? String,
              !value.isEmpty, value.utf16.count <= 1024 else {
            throw B1JSON.error(.invalidResponse)
        }
        return value
    }

    private func post(
        path: String,
        device: String,
        values: [String: String],
        rejection: XmlyError.Code,
        generation: UInt64,
        active: Pending? = nil
    ) async throws -> [String: Any] {
        var payload = values
        payload["signature"] = Self.signature(values: values)
        let body = Data(try B1JSON.encode(payload).utf8)
        let result = try await request(
            method: "POST",
            path: path,
            device: device,
            body: body,
            generation: generation,
            active: active
        )
        try check(result, rejection: rejection)
        return result
    }

    private func check(
        _ result: [String: Any],
        rejection: XmlyError.Code
    ) throws {
        let ret = B1JSON.text(result["ret"])
        guard ProtocolBytes.fullMatch(#"^-?[0-9]{1,9}$"#, ret) else {
            throw B1JSON.error(.invalidResponse)
        }
        guard ret == "0" else {
            throw B1JSON.error(rejection, definitive: true)
        }
    }

    private func request(
        method: String,
        path: String,
        device: String,
        body: Data?,
        generation: UInt64,
        active: Pending?
    ) async throws -> [String: Any] {
        guard let url = URL(string: XmlyOrigin.passport.rawValue + "/" + path) else {
            throw B1JSON.error(.invalidResponse)
        }
        var headers = [
            "Cookie": ProtocolConfig.mainAppCookie(for: device),
            "User-Agent": ProtocolConfig.mainAppUserAgent,
            "Cookie2": "$version=1",
            "Accept": "application/json, text/plain, */*"
        ]
        if body != nil { headers["Content-Type"] = "application/json" }

        let attempts = method == "GET" ? 4 : 1
        for attempt in 0..<attempts {
            try checkState(generation: generation, active: active)

            let response: PassportResponse
            do {
                response = try await transport.roundTrip(
                    method: method, url: url, headers: headers, body: body
                )
            } catch {
                // clear/过期优先于迟到的网络失败；取消不重试。
                try checkState(generation: generation, active: active)
                if error is CancellationError { throw CancellationError() }
                guard method == "GET", attempt + 1 < attempts else {
                    throw B1JSON.error(.networkError)
                }
                try await backoff(attempt)
                continue
            }

            try checkState(generation: generation, active: active)
            guard response.body.utf8.count <= 512 * 1024 else {
                throw B1JSON.error(.responseTooLarge)
            }
            guard response.statusCode == 200 else {
                let definitive = (400...499).contains(response.statusCode)
                    && response.statusCode != 429
                if definitive || method != "GET" {
                    throw B1JSON.error(.httpError, definitive: definitive)
                }
                guard attempt + 1 < attempts else {
                    // 对应 Kotlin：GET 重试耗尽后，HTTP 失败仍报 http_error
                    //（仅传输异常耗尽才报 network_error）。
                    throw B1JSON.error(.httpError, definitive: definitive)
                }
                try await backoff(attempt)
                continue
            }
            // 语法错误是无效响应，不属于传输失败，不重试。
            guard let result = try? JSONSerialization.jsonObject(
                with: Data(response.body.utf8)
            ) as? [String: Any] else {
                throw B1JSON.error(.invalidResponse)
            }
            return result
        }
        throw B1JSON.error(.networkError)
    }

    private func backoff(_ attempt: Int) async throws {
        try await Task<Never, Never>.sleep(
            nanoseconds: UInt64(500_000_000) << attempt
        )
    }

    private static func fallback(_ value: Any?, to other: Any?) -> Any? {
        guard let value else { return other }
        if let text = value as? String, text.isEmpty { return other }
        if let number = value as? NSNumber {
            // 注意：`as? Bool` 会把数值 0/0.0 也桥接为 false，
            // 故布尔判断必须先以 xmlyIsBoolean 鉴别真布尔。
            if xmlyIsBoolean(number) {
                if !number.boolValue { return other }
            } else if isIntegerZero(number) {
                return other
            }
        }
        // 显式 JSON null 与 Kotlin JSONObject.NULL 一致：不触发回退。
        return value
    }

    /// Kotlin `primary == 0`：仅整数 0 匹配，浮点 0.0 不匹配
    ///（JVM `Integer(0).equals(0)` 为真，`Double(0.0).equals(0)` 为假）。
    /// 以 CFNumber 类型区分；布尔已由调用方排除。
    private static func isIntegerZero(_ number: NSNumber) -> Bool {
        switch CFNumberGetType(number as CFNumber) {
        case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type,
             .shortType, .intType, .longType, .longLongType:
            return number.int64Value == 0
        default:
            return false
        }
    }

    private static func findString(
        root: [String: Any],
        keys: [String]
    ) -> String? {
        var queue: [Any] = [root]
        var cursor = 0
        while cursor < queue.count, cursor < 2000 {
            let node = queue[cursor]
            cursor += 1
            if let object = node as? [String: Any] {
                for key in keys {
                    if let value = object[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value
                    }
                }
                for key in object.keys.sorted() {
                    guard queue.count < 2000 else { break }
                    if let child = object[key],
                       child is [String: Any] || child is [Any] {
                        queue.append(child)
                    }
                }
            } else if let array = node as? [Any] {
                for child in array {
                    guard queue.count < 2000 else { break }
                    if child is [String: Any] || child is [Any] {
                        queue.append(child)
                    }
                }
            }
        }
        return nil
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [Waiter] = []

    private func acquire() async throws {
        if !busy {
            busy = true
            return
        }
        // 可取消等待（B1 M1 同款状态机，actor 内仲裁）：
        // 取消在入队前到达时，操作闭包内的 Task.isCancelled 检查直接抛错；
        // 取消在入队后到达时，处理器经 actor 移除并恢复该等待者。
        // 恢复前必先从队列移除，continuation 只恢复一次；取得所有权者
        // 已不在队列，不再响应取消；未取得门闩者不执行 release()。
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    // TODO 汇总：
    // 1. URLSession 无独立 connect/read/write 超时及关闭底层透明重试的开关；
    //    本实现只保证应用层 POST 单次提交，不能声称底层绝不透明重试。
    // 2. Kotlin Cookie 设备字符集宽于现有 Credentials；发送前已按
    //    Credentials 设备字符集校验（见 sendSms），后者继续作为最终边界。
}
