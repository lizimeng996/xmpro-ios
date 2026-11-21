// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

protocol HTTPTransport {
    func get(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any]

    func getData(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> Data

    func postJson(
        origin: String,
        path: String,
        query: [String: String],
        body: [String: Any],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any]

    func postForm(
        origin: String,
        path: String,
        query: [String: String],
        form: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any]

    func followRedirect(url: String) async -> String
}

final class XmlyHTTP: HTTPTransport {
    static let maxResponseBytes = 2 * 1024 * 1024
    static let collectorResponseBytes = 8 * 1024 * 1024

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

    private struct Outcome {
        let status: Int
        let body: Data
        let retryAfter: String?
    }

    private struct Retryable: Error {}

    private let session: URLSession
    private let ownsSession: Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let serverClock: ServerClock
    private let searchOrigin: String
    private let redirectDelegate = RedirectDelegate()
    private let cooldownLock = NSLock()
    private var cooldowns: [String: Date] = [:]

    init(
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = XmlyHTTP.defaultSleep,
        serverClock: ServerClock = .shared,
        searchOrigin: String = XmlyOrigin.search.rawValue
    ) {
        if let session {
            self.session = session
            ownsSession = false
        } else {
            self.session = Self.defaultSession()
            ownsSession = true
        }
        self.now = now
        self.sleep = sleep
        self.serverClock = serverClock
        self.searchOrigin = searchOrigin
    }

    deinit {
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        // URLSession has no separate public connect/read/write timeout controls.
        return URLSession(configuration: configuration)
    }

    @Sendable static func defaultSleep(_ seconds: TimeInterval) async {
        guard seconds.isFinite, seconds > 0 else {
            return
        }
        // Chunk very large Retry-After values without UInt64 overflow.
        var remaining = seconds
        while remaining > 0 && !Task.isCancelled {
            let chunk = min(remaining, 3600)
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: UInt64(chunk * 1_000_000_000)
                )
            } catch {
                return
            }
            remaining -= chunk
        }
    }

    func get(
        origin: String,
        path: String,
        query: [String: String] = [:],
        credentials: Credentials? = nil,
        signed: Bool = false,
        readOnly: Bool = true,
        headers: [String: String] = [:],
        responseLimit: Int? = nil
    ) async throws -> [String: Any] {
        try await execute(
            method: "GET", origin: origin, path: path, query: query,
            body: nil, contentType: nil, credentials: credentials,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        )
    }

    func getData(
        origin: String,
        path: String,
        query: [String: String] = [:],
        credentials: Credentials? = nil,
        signed: Bool = false,
        readOnly: Bool = true,
        headers: [String: String] = [:],
        responseLimit: Int? = nil
    ) async throws -> Data {
        try await executeResponse(
            method: "GET", origin: origin, path: path, query: query,
            body: nil, contentType: nil, credentials: credentials,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ) { outcome in
            try self.checkStatus(
                outcome, origin: origin, authenticated: credentials != nil
            )
            // 保序路径沿用 Kotlin 原端的业务 ret 校验；无效 JSON 交给上层解析器。
            // 此处不观察 timestamp，仍由 requestOrdered 在保序解析后处理。
            if let object = try? JSONSerialization.jsonObject(with: outcome.body),
               let payload = object as? [String: Any] {
                try self.checkBusinessCode(
                    self.businessCode(for: payload),
                    outcome: outcome,
                    origin: origin
                )
            }
            return outcome.body
        }
    }

    func postJson(
        origin: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any],
        credentials: Credentials? = nil,
        signed: Bool = false,
        readOnly: Bool = true,
        headers: [String: String] = [:],
        responseLimit: Int? = nil
    ) async throws -> [String: Any] {
        try requireCredentials(credentials, signed: signed)
        guard JSONSerialization.isValidJSONObject(body) else {
            throw XmlyError.failure(
                code: .invalidJSON, message: "接口返回无效 JSON"
            )
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: body,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw XmlyError.failure(
                code: .invalidJSON, message: "接口返回无效 JSON"
            )
        }
        return try await execute(
            method: "POST", origin: origin, path: path, query: query,
            body: data, contentType: "application/json",
            credentials: credentials, signed: signed, readOnly: readOnly,
            headers: headers, responseLimit: responseLimit
        )
    }

    func postForm(
        origin: String,
        path: String,
        query: [String: String] = [:],
        form: [String: String],
        credentials: Credentials? = nil,
        signed: Bool = false,
        readOnly: Bool = true,
        headers: [String: String] = [:],
        responseLimit: Int? = nil
    ) async throws -> [String: Any] {
        let encoded = form.keys.sorted(by: ProtocolBytes.utf8Less).map {
            Self.percentEncode($0, form: true)
                + "=" + Self.percentEncode(form[$0]!, form: true)
        }.joined(separator: "&")
        return try await execute(
            method: "POST", origin: origin, path: path, query: query,
            body: Data(encoded.utf8),
            contentType: "application/x-www-form-urlencoded",
            credentials: credentials, signed: signed, readOnly: readOnly,
            headers: headers, responseLimit: responseLimit
        )
    }

    private func requireCredentials(
        _ credentials: Credentials?,
        signed: Bool
    ) throws {
        if signed && credentials == nil {
            throw XmlyError.failure(
                code: .loginRequired,
                message: "签名请求需要登录",
                definitive: true
            )
        }
    }

    private func execute(
        method: String,
        origin: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String?,
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try await executeResponse(
            method: method, origin: origin, path: path, query: query,
            body: body, contentType: contentType, credentials: credentials,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ) { outcome in
            try self.interpret(
                outcome, origin: origin, authenticated: credentials != nil
            )
        }
    }

    private func executeResponse<Response>(
        method: String,
        origin: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String?,
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?,
        interpretOutcome: (Outcome) throws -> Response
    ) async throws -> Response {
        try requireCredentials(credentials, signed: signed)
        let limit = responseLimit ?? (
            origin == XmlyOrigin.collector.rawValue
                ? Self.collectorResponseBytes : Self.maxResponseBytes
        )
        guard limit >= 0 else {
            throw XmlyError.failure(
                code: .protocolError, message: "响应上限无效"
            )
        }

        for attempt in 0..<5 {
            try Task.checkCancellation()
            await waitForCooldown(origin)
            try Task.checkCancellation()

            do {
                let outcome = try await send(
                    method: method, origin: origin, path: path, query: query,
                    body: body, contentType: contentType,
                    credentials: credentials, signed: signed,
                    headers: headers, responseLimit: limit
                )
                return try interpretOutcome(outcome)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as XmlyError {
                throw error
            } catch is Retryable {
                if !readOnly || attempt == 4 {
                    throw XmlyError.failure(
                        code: readOnly ? .network : .uncertain,
                        message: readOnly
                            ? "喜马拉雅服务暂时不可用"
                            : "请求结果未知，请核对后重试"
                    )
                }
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if !readOnly || attempt == 4 {
                    throw XmlyError.failure(
                        code: readOnly ? .network : .uncertain,
                        message: readOnly
                            ? "请求失败或超时"
                            : "请求结果未知，请核对后重试"
                    )
                }
            }

            let backoff = TimeInterval(1 << attempt)
            await sleep(max(backoff, remainingCooldown(origin)))
        }
        throw XmlyError.failure(code: .network, message: "请求失败")
    }

    private func send(
        method: String,
        origin: String,
        path: String,
        query: [String: String],
        body: Data?,
        contentType: String?,
        credentials: Credentials?,
        signed: Bool,
        headers: [String: String],
        responseLimit: Int
    ) async throws -> Outcome {
        guard var components = URLComponents(string: origin + path),
              components.scheme == "https" || components.scheme == "http",
              components.host != nil else {
            throw XmlyError.failure(
                code: .protocolError, message: "接口地址无效"
            )
        }
        if !query.isEmpty {
            let added = query.keys.sorted(by: ProtocolBytes.utf8Less).map {
                Self.percentEncode($0, form: false)
                    + "=" + Self.percentEncode(query[$0]!, form: false)
            }.joined(separator: "&")
            if let previous = components.percentEncodedQuery, !previous.isEmpty {
                components.percentEncodedQuery = previous + "&" + added
            } else {
                components.percentEncodedQuery = added
            }
        }
        guard let url = components.url else {
            throw XmlyError.failure(
                code: .protocolError, message: "接口地址无效"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("close", forHTTPHeaderField: "Connection")
        for (key, value) in ProtocolConfig.originHeaders(origin: origin) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let credentials {
            request.setValue(credentials.cookie, forHTTPHeaderField: "Cookie")
        }
        if signed, let credentials {
            request.setValue(
                try XmlyCrypto.freshTicket(
                    credentials: credentials,
                    nowSeconds: serverClock.now() / 1000
                ),
                forHTTPHeaderField: "x-tk"
            )
        }
        request.httpBody = body
        if let contentType, body != nil {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: redirectDelegate
        )
        // Cancel on early exit, including Content-Length rejection and overflow.
        defer { bytes.task.cancel() }

        guard let response = response as? HTTPURLResponse else {
            throw XmlyError.failure(
                code: .invalidResponse, message: "接口响应无效"
            )
        }
        serverClock.observeDateHeader(
            response.value(forHTTPHeaderField: "Date")
        )

        if let header = response.value(forHTTPHeaderField: "Content-Length"),
           let declared = Int64(header.trimmingCharacters(in: .whitespaces)),
           declared > Int64(responseLimit) {
            throw tooLarge(responseLimit)
        }

        var data = Data()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(16 * 1024)
        var received = 0
        for try await byte in bytes {
            guard received < responseLimit else {
                throw tooLarge(responseLimit)
            }
            received += 1
            chunk.append(byte)
            if chunk.count == 16 * 1024 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: chunk)
        return Outcome(
            status: response.statusCode,
            body: data,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After")
        )
    }

    private func checkStatus(
        _ outcome: Outcome,
        origin: String,
        authenticated: Bool
    ) throws {
        let status = outcome.status
        if status == 429 {
            let wait = retryAfter(outcome.retryAfter) ?? 30
            setCooldown(origin, seconds: wait)
            throw rateLimited(wait)
        }
        if status == 401 || (status == 403 && authenticated) {
            throw loginExpired()
        }
        if (500...599).contains(status) {
            throw Retryable()
        }
        guard status == 200 else {
            let clientError = (400...499).contains(status)
            throw XmlyError.failure(
                code: clientError ? .rejected : .protocolError,
                message: "接口返回 HTTP \(status)",
                definitive: clientError
            )
        }
        guard !outcome.body.isEmpty else {
            throw XmlyError.failure(
                code: .invalidJSON, message: "接口响应为空"
            )
        }
    }

    private func interpret(
        _ outcome: Outcome,
        origin: String,
        authenticated: Bool
    ) throws -> [String: Any] {
        try checkStatus(outcome, origin: origin, authenticated: authenticated)

        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: outcome.body
            ) as? [String: Any] else {
                throw XmlyError.failure(
                    code: .invalidJSON, message: "接口返回无效 JSON"
                )
            }
            payload = object
        } catch {
            throw XmlyError.failure(
                code: .invalidJSON, message: "接口返回无效 JSON"
            )
        }

        serverClock.observePayload(timestamp: payload["timestamp"])
        try checkBusinessCode(
            businessCode(for: payload), outcome: outcome, origin: origin
        )
        return payload
    }

    private func businessCode(for payload: [String: Any]) -> String {
        if payload["ret"] == nil {
            return "0"
        } else if let string = payload["ret"] as? String {
            return string
        } else if let number = payload["ret"] as? NSNumber {
            return number.stringValue
        } else if payload["ret"] is NSNull {
            return "null"
        } else {
            return "invalid"
        }
    }

    private func checkBusinessCode(
        _ code: String,
        outcome: Outcome,
        origin: String
    ) throws {
        let expected = origin == searchOrigin ? "200" : "0"
        guard code != expected else {
            return
        }

        switch code {
        case "429":
            // Business-layer rate limiting honours Retry-After exactly
            // like HTTP 429 does; only the fallback is a fixed 30s.
            let wait = retryAfter(outcome.retryAfter) ?? 30
            setCooldown(origin, seconds: wait)
            throw rateLimited(wait)
        case "401":
            throw loginExpired()
        case "5", "403", "726":
            throw XmlyError.failure(
                code: .permissionDenied,
                message: "未获得本次请求的完整权限，请检查账号、听时和版权限制",
                definitive: true
            )
        case "4", "-4":
            throw XmlyError.failure(
                code: .rejected,
                message: "喜马拉雅拒绝了请求（ret=\(code)）：听时额度或设备状态异常，请到官方 App 核对后再试",
                definitive: true
            )
        case "-400":
            throw XmlyError.failure(
                code: .badTimestamp,
                message: "请求校验失败（设备时间与服务端偏差过大），请校准时间后重试",
                definitive: true
            )
        default:
            // Never interpolate the server's ret value into an error:
            // it is attacker-controlled text and could carry a phone
            // number or credential fragment into user-visible UI.
            // Only the whitelisted protocol codes above may be shown.
            throw XmlyError.failure(
                code: .rejected,
                message: "喜马拉雅拒绝了请求",
                definitive: true
            )
        }
    }

    func followRedirect(url: String) async -> String {
        var current = url
        for _ in 0..<4 {
            if Task.isCancelled {
                return current
            }
            guard let parsed = URL(string: current),
                  parsed.scheme == "https" || parsed.scheme == "http",
                  parsed.host != nil else {
                return current
            }
            var request = URLRequest(url: parsed)
            request.timeoutInterval = 25
            request.httpShouldHandleCookies = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.setValue("*/*", forHTTPHeaderField: "Accept")

            do {
                let (bytes, response) = try await session.bytes(
                    for: request,
                    delegate: redirectDelegate
                )
                bytes.task.cancel()
                guard let response = response as? HTTPURLResponse else {
                    return current
                }
                serverClock.observeDateHeader(
                    response.value(forHTTPHeaderField: "Date")
                )
                guard (300...399).contains(response.statusCode),
                      let location = response.value(
                        forHTTPHeaderField: "Location"
                      ) else {
                    return current
                }
                if location.hasPrefix("http://") {
                    current = "https://" + String(location.dropFirst(7))
                } else {
                    // Preserve Kotlin's behavior for relative Location values.
                    current = location
                }
            } catch {
                return current
            }
        }
        return current
    }

    private func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value else {
            return nil
        }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int64(text) {
            return seconds >= 0 ? TimeInterval(seconds) : nil
        }
        guard let date = ServerClock.parseHTTPDate(text) else {
            return nil
        }
        let seconds = date.timeIntervalSince(now())
        return seconds >= 0 ? seconds : nil
    }

    private func setCooldown(_ origin: String, seconds: TimeInterval) {
        let until = now().addingTimeInterval(seconds)
        cooldownLock.lock()
        // Keep the later deadline: a short cooldown must never shorten
        // a longer one set by a concurrent request.
        if let existing = cooldowns[origin], existing > until {
            cooldownLock.unlock()
            return
        }
        cooldowns[origin] = until
        cooldownLock.unlock()
    }

    private func remainingCooldown(_ origin: String) -> TimeInterval {
        cooldownLock.lock()
        let until = cooldowns[origin]
        cooldownLock.unlock()
        return max(0, until?.timeIntervalSince(now()) ?? 0)
    }

    private func waitForCooldown(_ origin: String) async {
        // Re-check after each sleep so a cooldown extended by another
        // request is honoured. The iteration cap only bounds pathological
        // injections where the clock never advances; real clocks always do.
        for _ in 0..<64 {
            let delay = remainingCooldown(origin)
            guard delay > 0 else {
                return
            }
            if Task.isCancelled {
                return
            }
            await sleep(delay)
        }
    }

    private func rateLimited(_ seconds: TimeInterval) -> XmlyError {
        .failure(
            code: .rateLimited,
            message: "请求过于频繁，请稍后重试",
            definitive: true,
            retryAfter: seconds
        )
    }

    private func loginExpired() -> XmlyError {
        .failure(
            code: .loginExpired,
            message: "登录信息已失效，请重新登录",
            definitive: true
        )
    }

    private func tooLarge(_ limit: Int) -> XmlyError {
        .failure(
            code: .responseTooLarge,
            message: "响应超过 \(limit / (1024 * 1024)) MiB 上限"
        )
    }

    private static func percentEncode(_ value: String, form: Bool) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []
        for byte in value.utf8 {
            let alphanumeric = (65...90).contains(byte)
                || (97...122).contains(byte)
                || (48...57).contains(byte)
            let punctuation = byte == 45 || byte == 46 || byte == 95
                || (form ? byte == 42 : byte == 126)
            if alphanumeric || punctuation {
                result.append(byte)
            } else if form && byte == 32 {
                result.append(43)
            } else {
                result.append(37)
                result.append(hex[Int(byte >> 4)])
                result.append(hex[Int(byte & 15)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
