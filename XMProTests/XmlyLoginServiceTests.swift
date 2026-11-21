
import XCTest
import Foundation
@testable import XMPro

private final class LoginTime: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds: Int64 = 1_700_000_000_000

    func date() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    func advance(_ value: Int64) {
        lock.lock()
        defer { lock.unlock() }
        milliseconds += value
    }
}

private actor PassportFake: PassportTransport {
    enum Step {
        case response(Int, String)
        case failure
    }

    private var steps: [Step] = []
    private var methods: [String] = []
    private var paths: [String] = []
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var holdObserver: CheckedContinuation<Void, Never>?

    func append(_ values: [Step]) {
        steps.append(contentsOf: values)
    }

    func hold() {
        holdNext = true
    }

    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { holdObserver = $0 }
    }

    func resume() {
        held?.resume()
        held = nil
    }

    func counts() -> (get: Int, post: Int) {
        (methods.filter { $0 == "GET" }.count,
         methods.filter { $0 == "POST" }.count)
    }

    func roundTrip(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> PassportResponse {
        methods.append(method)
        paths.append(url.path)
        // 不存储或输出 Cookie、请求体。
        let step = steps.isEmpty ? Step.failure : steps.removeFirst()
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                holdObserver?.resume()
                holdObserver = nil
            }
        }
        switch step {
        case .response(let status, let text):
            return (status, text)
        case .failure:
            throw URLError(.timedOut)
        }
    }
}

final class XmlyLoginServiceTests: XCTestCase {
    private struct Fixture {
        let fake: PassportFake
        let time: LoginTime
        let service: XmlyLoginService
    }

    private func fixture() -> Fixture {
        let fake = PassportFake()
        let time = LoginTime()
        return Fixture(
            fake: fake,
            time: time,
            service: XmlyLoginService(
                transport: fake,
                clock: ServerClock(now: { time.date() }),
                deviceOverride: "fixture-device"
            )
        )
    }

    private func mobile(_ suffix: Int = 0) -> String {
        // 合成输入，不在断言失败信息中输出。
        String(10_000_000 + suffix)
    }

    private func fields(_ lot: String = "fixture-lot") -> [String: String] {
        [
            "captcha_id": GeetestChallenge.captchaID,
            "lot_number": lot,
            "pass_token": "fixture-pass",
            "gen_time": "1",
            "captcha_output": "fixture-output"
        ]
    }

    private func response(_ object: [String: Any]) throws -> PassportFake.Step {
        .response(200, try B1JSON.encode(object))
    }

    private func seedSend(_ fixture: Fixture) async throws {
        await fixture.fake.append([
            try response(["nonce": "fixture-nonce"]),
            try response(["ret": 0])
        ])
    }

    private func send(_ fixture: Fixture) async throws -> String {
        try await seedSend(fixture)
        return try await fixture.service.sendSms(
            mobile: mobile(), geetest: fields()
        )
    }

    private func seedVerify(
        _ fixture: Fixture,
        key: [String: Any] = ["ret": 0, "bizKey": "fixture-key"],
        login: [String: Any]? = nil
    ) async throws {
        let login = login ?? [
            "ret": 0,
            "data": ["uid": "7", "token": "fixture-token"]
        ]
        await fixture.fake.append([
            try response(["nonce": "fixture-nonce"]),
            try response(key),
            try response(["nonce": "fixture-nonce"]),
            try response(login)
        ])
    }

    private func expect(
        _ code: XmlyError.Code,
        definitive: Bool,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("预期固定错误码")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, code.rawValue)
            XCTAssertEqual(error.definitive, definitive)
        } catch {
            XCTFail("错误类型不符合契约")
        }
    }

    func testConfig() {
        let config = fixture().service.config()
        XCTAssertEqual(config["biz"] as? Int, 1)
        XCTAssertTrue(config["captcha_id"] as? String == GeetestChallenge.captchaID)
        XCTAssertEqual(
            config["captcha_fields"] as? [String],
            GeetestChallenge.fields.sorted()
        )
    }

    func testSignatureGoldenVectors() {
        let vectors: [([String: String], String)] = [
            (["biz": "1"], "8428838bf0ec3fcd05c1df9819b5f19d40b21b23"),
            (["biz": "1", "mobile": "x"], "ac7713a414dcf4a504e6b10ee69a23b665e3982b"),
            ([:], "b883c89f2468a7ce872abdbe84a130d44fecb2f1")
        ]
        for (input, expected) in vectors {
            // XCTAssertTrue 避免 XCTest 在失败时打印完整摘要。
            XCTAssertTrue(XmlyLoginService.signature(values: input) == expected)
        }
    }

    func testMobileValidation() async {
        for input in ["", "123", "123456\n", "++123456", String(repeating: "1", count: 19)] {
            let f = fixture()
            await expect(.invalidMobile, definitive: true) {
                _ = try await f.service.sendSms(mobile: input, geetest: self.fields())
            }
        }
    }

    func testCaptchaValidation() async {
        for key in GeetestChallenge.fields {
            for bad in [Optional<String>.none, "", "has space", "\n", "中文",
                        String(repeating: "x", count: 8193)] {
                let f = fixture()
                var value = fields()
                value[key] = bad
                await expect(.invalidCaptcha, definitive: true) {
                    _ = try await f.service.sendSms(mobile: self.mobile(), geetest: value)
                }
            }
        }
        let f = fixture()
        var value = fields()
        value["captcha_id"] = "wrong"
        await expect(.invalidCaptcha, definitive: true) {
            _ = try await f.service.sendSms(mobile: self.mobile(), geetest: value)
        }
    }

    func testDeviceValidation() async {
        for input in ["x;y", "x&y", "x,y", "x\"y", "x\\y", "x y", "x\u{7f}",
                      String(repeating: "x", count: 129)] {
            let f = fixture()
            await expect(.invalidDevice, definitive: true) {
                _ = try await f.service.sendSms(
                    mobile: self.mobile(), geetest: self.fields(), device: input
                )
            }
        }
    }

    func testDeviceRejectedByCredentialsCharset() async {
        // 通过登录 Cookie 校验、但不在 Credentials 字符集内的设备
        //（如 `/`、`!`、`#`），发送前即以 invalid_device 拒绝，不发任何请求。
        for device in ["a/b", "a!b", "a#b"] {
            let f = fixture()
            await expect(.invalidDevice, definitive: true) {
                _ = try await f.service.sendSms(
                    mobile: self.mobile(), geetest: self.fields(), device: device
                )
            }
            let counts = await f.fake.counts()
            XCTAssertEqual(counts.get, 0)
            XCTAssertEqual(counts.post, 0)
        }
    }

    func testNumericZeroFallbackIsIntegerOnly() async throws {
        // Kotlin `primary == 0`：仅整数 0 触发回退，浮点 0.0 不触发。
        let f = fixture()
        let id = try await send(f)
        try await seedVerify(f, key: ["ret": 0, "bizKey": 0, "smsKey": "fixture-key"])
        _ = try await f.service.verifySms(challengeId: id, code: "1234")

        let g = fixture()
        let gid = try await send(g)
        await g.fake.append([
            try response(["nonce": "fixture-nonce"]),
            .response(200, #"{"ret":0,"bizKey":0.0,"smsKey":"fixture-key"}"#)
        ])
        await expect(.invalidResponse, definitive: false) {
            _ = try await g.service.verifySms(challengeId: gid, code: "1234")
        }
        let counts = await g.fake.counts()
        XCTAssertEqual(counts.post, 2)
    }

    func testQueuedWaiterCancelsPromptly() async throws {
        // B 被门闩排队后取消：须在 A 仍被 hold 时即结束，不发任何请求。
        let f = fixture()
        try await seedSend(f)
        await f.fake.hold()
        let taskA = Task {
            try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        await f.fake.waitUntilHeld()
        let taskB = Task {
            try await f.service.sendSms(mobile: self.mobile(1), geetest: self.fields("lot-b"))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        taskB.cancel()
        do {
            _ = try await taskB.value
            XCTFail("预期取消错误")
        } catch is CancellationError {
            // 预期：排队等待者被取消后立即结束。
        } catch {
            XCTFail("错误类型不符合契约")
        }
        let counts = await f.fake.counts()
        XCTAssertEqual(counts.get, 1)
        XCTAssertEqual(counts.post, 0)
        await f.fake.resume()
        _ = try await taskA.value
    }

    func testChallengeFormatAndCaseInsensitiveCaptcha() async throws {
        let f = fixture()
        try await seedSend(f)
        var value = fields()
        value["captcha_id"] = GeetestChallenge.captchaID.uppercased()
        let id = try await f.service.sendSms(mobile: mobile(), geetest: value)
        XCTAssertTrue(ProtocolBytes.fullMatch(#"^[A-Za-z0-9_-]{43}$"#, id))
        XCTAssertEqual(ProtocolBytes.decodeBase64URL(id)?.count, 32)
    }

    func testLotReuseAndTenMinuteBoundary() async throws {
        let f = fixture()
        _ = try await send(f)
        f.time.advance(599_999)
        await expect(.captchaReused, definitive: true) {
            _ = try await f.service.sendSms(
                mobile: self.mobile(1), geetest: self.fields()
            )
        }
        f.time.advance(1)
        try await seedSend(f)
        _ = try await f.service.sendSms(mobile: mobile(1), geetest: fields())
    }

    func testSmsCooldownAndThreeMinuteBoundary() async throws {
        let f = fixture()
        _ = try await send(f)
        f.time.advance(179_999)
        await expect(.smsCooldown, definitive: true) {
            _ = try await f.service.sendSms(
                mobile: "+" + self.mobile(), geetest: self.fields("new-lot")
            )
        }
        f.time.advance(1)
        try await seedSend(f)
        _ = try await f.service.sendSms(mobile: mobile(), geetest: fields("new-lot"))
    }

    func testChallengeAndCodeValidation() async {
        let f = fixture()
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: "!", code: "1234")
        }
        for code in ["", "123", "123456789", "1234\n", "abcd"] {
            await expect(.invalidCode, definitive: true) {
                _ = try await f.service.verifySms(challengeId: "valid", code: code)
            }
        }
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: "valid", code: "1234")
        }
    }

    func testMismatchedPendingAndExpiry() async throws {
        let f = fixture()
        let id = try await send(f)
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: "other", code: "1234")
        }
        f.time.advance(600_000)
        await expect(.challengeExpired, definitive: true) {
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }
    }

    func testFiveAttemptsClearPending() async throws {
        let f = fixture()
        let id = try await send(f)
        for _ in 0..<5 {
            await f.fake.append([
                try response(["nonce": "fixture-nonce"]),
                try response(["ret": 1])
            ])
            await expect(.smsVerifyRejected, definitive: true) {
                _ = try await f.service.verifySms(challengeId: id, code: "1234")
            }
        }
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }
        let counts = await f.fake.counts()
        XCTAssertEqual(counts.post, 6)
    }

    func testSmsKeyFallbacks() async throws {
        let alternatives: [Any?] = [nil, "", false, 0]
        for primary in alternatives {
            let f = fixture()
            let id = try await send(f)
            var key: [String: Any] = ["ret": 0, "smsKey": "fixture-key"]
            key["bizKey"] = primary
            try await seedVerify(f, key: key)
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }
    }

    func testInvalidBizKeyDoesNotContinue() async throws {
        for key: Any in [NSNull(), true, 9, "", String(repeating: "x", count: 8193)] {
            let f = fixture()
            let id = try await send(f)
            await f.fake.append([
                try response(["nonce": "fixture-nonce"]),
                try response(["ret": 0, "bizKey": key])
            ])
            await expect(.invalidResponse, definitive: false) {
                _ = try await f.service.verifySms(challengeId: id, code: "1234")
            }
            let counts = await f.fake.counts()
            XCTAssertEqual(counts.post, 2)
        }
    }

    func testInvalidUidAndToken() async throws {
        let invalid: [[String: Any]] = [
            ["uid": "0", "token": "fixture-token"],
            ["uid": "01", "token": "fixture-token"],
            ["uid": true, "token": "fixture-token"],
            ["uid": "7", "token": "bad token"],
            ["uid": "7", "token": false],
            ["uid": "7", "token": String(repeating: "x", count: 8193)]
        ]
        for values in invalid {
            let f = fixture()
            let id = try await send(f)
            try await seedVerify(f, login: values.merging(["ret": 0]) { _, new in new })
            await expect(.invalidResponse, definitive: false) {
                _ = try await f.service.verifySms(challengeId: id, code: "1234")
            }
        }
    }

    func testSuccessAndBreadthFirstProfile() async throws {
        let f = fixture()
        let id = try await send(f)
        let profileMobile = mobile(2)
        try await seedVerify(f, login: [
            "ret": 0,
            "uid": "8",
            "token": "fixture-top-token",
            "data": ["uid": "9", "token": "fixture-nested-token"],
            "a": ["deep": ["nickname": "deep-name"]],
            "b": [
                "nickname": "near-name",
                "avatarUrl": "https://example.invalid/avatar",
                "mobilePhone": profileMobile
            ]
        ])
        let result = try await f.service.verifySms(challengeId: id, code: "1234")
        XCTAssertTrue(result.credentials.uid == "8")
        XCTAssertTrue(result.credentials.tokenAfterUID == "fixture-top-token")
        XCTAssertTrue(result.credentials.deviceId == "fixture-device")
        XCTAssertEqual(result.nickname, "near-name")
        XCTAssertTrue(result.avatarUrl == "https://example.invalid/avatar")
        XCTAssertTrue(result.mobile == profileMobile)
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }
    }

    func testClearInvalidatesPendingAndInFlightSend() async throws {
        let f = fixture()
        let id = try await send(f)
        await f.service.clear()
        await expect(.challengeInvalid, definitive: true) {
            _ = try await f.service.verifySms(challengeId: id, code: "1234")
        }

        let g = fixture()
        try await seedSend(g)
        await g.fake.hold()
        let task = Task {
            try await g.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        await g.fake.waitUntilHeld()
        await g.service.clear()
        await g.fake.resume()
        await expect(.challengeInvalid, definitive: true) {
            _ = try await task.value
        }
        let counts = await g.fake.counts()
        XCTAssertEqual(counts.post, 0)
    }

    func testNonceAndRetValidation() async throws {
        let invalidNonce: [[String: Any]] = [
            [:], ["nonce": ""], ["nonce": String(repeating: "x", count: 1025)],
            ["nonce": "n", "ret": true], ["nonce": "n", "ret": NSNull()],
            ["nonce": "n", "ret": "0\n"]
        ]
        for value in invalidNonce {
            let f = fixture()
            await f.fake.append([try response(value)])
            await expect(.invalidResponse, definitive: false) {
                _ = try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
            }
        }
        let f = fixture()
        await f.fake.append([try response(["nonce": "n", "ret": 1])])
        await expect(.nonceRejected, definitive: true) {
            _ = try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let g = fixture()
        await g.fake.append([
            try response(["nonce": "n"]), try response(["ret": 1])
        ])
        await expect(.smsSendRejected, definitive: true) {
            _ = try await g.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let h = fixture()
        let id = try await send(h)
        try await seedVerify(h, login: ["ret": 1])
        await expect(.quickLoginRejected, definitive: true) {
            _ = try await h.service.verifySms(challengeId: id, code: "1234")
        }
    }

    func testGetRetriesButPostDoesNotReplay() async throws {
        let f = fixture()
        await f.fake.append([
            .failure, .response(503, "{}"), .response(429, "{}"),
            try response(["nonce": "n"]), .failure
        ])
        await expect(.networkError, definitive: false) {
            _ = try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let counts = await f.fake.counts()
        XCTAssertEqual(counts.get, 4)
        XCTAssertEqual(counts.post, 1)

        let g = fixture()
        await g.fake.append(Array(repeating: .response(503, "{}"), count: 4))
        // 对应 Kotlin：GET 重试耗尽后 HTTP 失败仍报 http_error
        //（仅传输异常耗尽才报 network_error）。
        await expect(.httpError, definitive: false) {
            _ = try await g.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let exhausted = await g.fake.counts()
        XCTAssertEqual(exhausted.get, 4)
        XCTAssertEqual(exhausted.post, 0)
    }

    func testResponseSizeAndMalformedJson() async throws {
        let f = fixture()
        await f.fake.append([.response(200, String(repeating: "x", count: 512 * 1024 + 1))])
        await expect(.responseTooLarge, definitive: false) {
            _ = try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }

        let g = fixture()
        let base = #"{"nonce":"n"}"#
        await g.fake.append([
            .response(200, base + String(repeating: " ", count: 512 * 1024 - base.utf8.count)),
            try response(["ret": 0])
        ])
        _ = try await g.service.sendSms(mobile: mobile(), geetest: fields())

        let h = fixture()
        await h.fake.append([.response(200, "{")])
        await expect(.invalidResponse, definitive: false) {
            _ = try await h.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let counts = await h.fake.counts()
        XCTAssertEqual(counts.get, 1)
    }

    func testHttpDefinitiveRules() async throws {
        for status in [400, 401, 403, 404, 429, 500] {
            let f = fixture()
            await f.fake.append([
                try response(["nonce": "n"]), .response(status, "{}")
            ])
            await expect(
                .httpError,
                definitive: (400...499).contains(status) && status != 429
            ) {
                _ = try await f.service.sendSms(mobile: self.mobile(), geetest: self.fields())
            }
            let counts = await f.fake.counts()
            XCTAssertEqual(counts.post, 1)
        }
        let g = fixture()
        await g.fake.append([.response(403, "{}")])
        await expect(.httpError, definitive: true) {
            _ = try await g.service.sendSms(mobile: self.mobile(), geetest: self.fields())
        }
        let counts = await g.fake.counts()
        XCTAssertEqual(counts.get, 1)
    }
}
