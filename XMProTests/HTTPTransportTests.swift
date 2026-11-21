// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import XMPro

final class HTTPTransportTests: XCTestCase {
    /*
     Deterministic HTTP tests: the transport runs against a URLProtocol
     stub with an injected session, fake clock, and recording sleep.
     The fake sleep advances the fake clock, so cooldown waits terminate.
     Nothing here touches the network; the fixture credential is synthetic.
     */

    private final class StubURLProtocol: URLProtocol {
        struct Planned {
            let status: Int
            let headers: [String: String]
            let body: Data
        }

        // Tests run serially; plain static state is sufficient here.
        // The lock only guards the shared log/handler against the
        // concurrent-request test's two protocol callbacks.
        private static let lock = NSLock()
        static var respond: ((URLRequest) -> Planned)?
        static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(
            for request: URLRequest
        ) -> URLRequest {
            request
        }

        override func startLoading() {
            Self.lock.lock()
            Self.requests.append(request)
            let handler = Self.respond
            Self.lock.unlock()
            guard let planned = handler?(request) else {
                client?.urlProtocol(
                    self, didFailWithError: URLError(.badServerResponse)
                )
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: planned.status,
                httpVersion: "HTTP/1.1",
                headerFields: planned.headers
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if !planned.body.isEmpty {
                client?.urlProtocol(self, didLoad: planned.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var sleeps: [TimeInterval] = []
    }

    override func tearDown() {
        StubURLProtocol.respond = nil
        StubURLProtocol.requests = []
        super.tearDown()
    }

    private static func jsonData(_ json: [String: Any]) -> Data {
        // Test fixtures only.
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: json)
    }

    private static func ok(_ json: [String: Any]) -> StubURLProtocol.Planned {
        .init(status: 200, headers: [:], body: jsonData(json))
    }

    private func makeHTTP() -> (XmlyHTTP, FakeClock) {
        let fake = FakeClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clock = ServerClock(now: { fake.now })
        let http = XmlyHTTP(
            session: session,
            now: { fake.now },
            sleep: { interval in
                fake.sleeps.append(interval)
                fake.now = fake.now.addingTimeInterval(interval)
            },
            serverClock: clock
        )
        return (http, fake)
    }

    private func fixtureCredentials() throws -> Credentials {
        // Synthetic local fixture; never a user credential.
        try Credentials(
            token: "123456&fixture-token",
            deviceId: "android-0123456789abcdef"
        )
    }

    private func expectCode(
        _ expected: String,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(name): expected an error", file: file, line: line)
        } catch let error as XmlyError {
            if error.code != expected {
                XCTFail(
                    "\(name): unexpected error code \(error.code)",
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail("\(name): unexpected error type", file: file, line: line)
        }
    }

    func testGetSendsCookieAndTicketAndReturnsPayload() async throws {
        let (http, _) = makeHTTP()
        let credentials = try fixtureCredentials()
        StubURLProtocol.respond = { _ in
            Self.ok(["ret": 0, "data": ["ok": true]])
        }

        let payload = try await http.get(
            origin: XmlyOrigin.mobile.rawValue,
            path: "/x",
            credentials: credentials,
            signed: true
        )
        XCTAssertEqual(payload["ret"] as? Int, 0, "http.payload")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "http.requests")
        let request = StubURLProtocol.requests[0]
        XCTAssertEqual(request.httpMethod, "GET", "http.method")
        assertSame(
            request.value(forHTTPHeaderField: "Cookie") ?? "",
            credentials.cookie,
            "http.cookie"
        )
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "x-tk")?
                .hasPrefix("TAC") == true,
            "http.ticket"
        )
    }

    func testReadOnlyRetriesServerErrorsThenSucceeds() async throws {
        let (http, fake) = makeHTTP()
        var calls = 0
        StubURLProtocol.respond = { _ in
            calls += 1
            if calls <= 2 {
                return .init(status: 500, headers: [:], body: Data())
            }
            return Self.ok(["ret": 0])
        }

        let payload = try await http.get(
            origin: XmlyOrigin.mobile.rawValue, path: "/x"
        )
        XCTAssertEqual(payload["ret"] as? Int, 0, "http.retryPayload")
        XCTAssertEqual(StubURLProtocol.requests.count, 3, "http.retryCount")
        XCTAssertEqual(fake.sleeps, [1, 2], "http.retryBackoff")
    }

    func testWriteRequestDoesNotRetryAndReportsUncertain() async throws {
        let (http, fake) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(status: 500, headers: [:], body: Data())
        }

        await expectCode("uncertain", name: "http.write500") {
            _ = try await http.postJson(
                origin: XmlyOrigin.mobile.rawValue,
                path: "/x",
                body: ["a": "b"],
                readOnly: false
            )
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "http.writeCount")
        XCTAssertTrue(fake.sleeps.isEmpty, "http.writeNoSleep")
    }

    func testHTTP429HonoursRetryAfter() async throws {
        let (http, fake) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(
                status: 429,
                headers: ["Retry-After": "5"],
                body: Data()
            )
        }

        do {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
            XCTFail("http.429: expected rate_limited")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "rate_limited", "http.429code")
            XCTAssertEqual(error.retryAfter ?? -1, 5, "http.429retryAfter")
        }

        StubURLProtocol.respond = { _ in Self.ok(["ret": 0]) }
        let payload = try await http.get(
            origin: XmlyOrigin.mobile.rawValue, path: "/x"
        )
        XCTAssertEqual(payload["ret"] as? Int, 0, "http.429after")
        XCTAssertEqual(fake.sleeps, [5], "http.429cooldownWait")
    }

    func testBusinessRet429HonoursRetryAfter() async throws {
        let (http, _) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(
                status: 200,
                headers: ["Retry-After": "7"],
                body: Self.jsonData(["ret": "429"])
            )
        }

        do {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
            XCTFail("http.biz429: expected rate_limited")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "rate_limited", "http.biz429code")
            XCTAssertEqual(error.retryAfter ?? -1, 7, "http.biz429retryAfter")
        }
    }

    func testGetDataBusinessRet429HonoursRetryAfterAndCooldown() async throws {
        let (http, fake) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(
                status: 200,
                headers: ["Retry-After": "7"],
                body: Data(#"{"ret":"429"}"#.utf8)
            )
        }

        do {
            _ = try await http.getData(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
            XCTFail("http.dataBiz429: expected rate_limited")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "rate_limited", "http.dataBiz429code")
            XCTAssertEqual(error.retryAfter ?? -1, 7, "http.dataBiz429retryAfter")
        }

        XCTAssertTrue(fake.sleeps.isEmpty, "http.dataBiz429noRetry")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "http.dataBiz429count")

        let body = Data(#"{"ret":0}"#.utf8)
        StubURLProtocol.respond = { _ in
            // 对齐字典路径：同一 origin 的下一次请求必须先等完冷却。
            XCTAssertEqual(fake.sleeps, [7], "http.dataBiz429beforeSend")
            return .init(status: 200, headers: [:], body: body)
        }
        let data = try await http.getData(
            origin: XmlyOrigin.mobile.rawValue, path: "/x"
        )
        XCTAssertEqual(data, body, "http.dataBiz429after")
        XCTAssertEqual(fake.sleeps, [7], "http.dataBiz429cooldownWait")
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "http.dataBiz429afterCount")
    }

    func testGetDataNumericRet401ReportsLoginExpired() async throws {
        let (http, _) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: Data(#"{"ret":401}"#.utf8))
        }

        await expectCode("login_expired", name: "http.dataRet401") {
            _ = try await http.getData(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
        }
    }

    func testGetDataNumericRet5ReportsPermissionDenied() async throws {
        let (http, _) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: Data(#"{"ret":5}"#.utf8))
        }

        await expectCode("permission_denied", name: "http.dataRet5") {
            _ = try await http.getData(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
        }
    }

    func testGetDataReturnsSuccessfulObjectBodyUnchanged() async throws {
        let (http, _) = makeHTTP()
        let body = Data(#"{"ret":0,"data":{"x":1}}"#.utf8)
        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: body)
        }

        let data = try await http.getData(
            origin: XmlyOrigin.mobile.rawValue, path: "/x"
        )
        XCTAssertEqual(data, body, "http.dataObjectBytes")
    }

    func testGetDataReturnsNonObjectBodyUnchanged() async throws {
        let (http, _) = makeHTTP()
        let body = Data("[]".utf8)
        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: body)
        }

        let data = try await http.getData(
            origin: XmlyOrigin.mobile.rawValue, path: "/x"
        )
        XCTAssertEqual(data, body, "http.dataArrayBytes")
    }

    func testGetDataSearchOriginExpectsRet200() async throws {
        let (http, _) = makeHTTP()
        let body = Data(#"{"ret":200}"#.utf8)
        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: body)
        }

        let data = try await http.getData(
            origin: XmlyOrigin.search.rawValue, path: "/x"
        )
        XCTAssertEqual(data, body, "http.dataSearch200")

        StubURLProtocol.respond = { _ in
            .init(status: 200, headers: [:], body: Data(#"{"ret":0}"#.utf8))
        }
        await expectCode("rejected", name: "http.dataSearch0") {
            _ = try await http.getData(
                origin: XmlyOrigin.search.rawValue, path: "/x"
            )
        }
    }

    func testRetCodeMapping() async throws {
        let (http, _) = makeHTTP()
        let cases: [(Any, String)] = [
            ("5", "permission_denied"),
            ("4", "rejected"),
            ("-400", "bad_timestamp"),
            ("401", "login_expired"),
            ("999", "rejected"),
        ]
        for (ret, code) in cases {
            StubURLProtocol.respond = { _ in Self.ok(["ret": ret]) }
            await expectCode(code, name: "http.ret.\(ret)") {
                _ = try await http.get(
                    origin: XmlyOrigin.mobile.rawValue, path: "/x"
                )
            }
        }

        // Unknown numeric codes use a fixed message: no server value leaks.
        StubURLProtocol.respond = { _ in Self.ok(["ret": "999"]) }
        do {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
            XCTFail("http.ret.unknown: expected error")
        } catch let error as XmlyError {
            XCTAssertEqual(
                error.message, "喜马拉雅拒绝了请求", "http.ret.unknownMessage"
            )
            XCTAssertFalse(
                error.message.contains("999"), "http.ret.unknownNoLeak"
            )
        }
    }

    func testHTTPStatusMapping() async throws {
        let (http, _) = makeHTTP()

        StubURLProtocol.respond = { _ in
            .init(status: 401, headers: [:], body: Data())
        }
        await expectCode("login_expired", name: "http.status401") {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
        }

        StubURLProtocol.respond = { _ in
            .init(status: 403, headers: [:], body: Data())
        }
        await expectCode("rejected", name: "http.status403anon") {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue, path: "/x"
            )
        }
        await expectCode("login_expired", name: "http.status403auth") {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue,
                path: "/x",
                credentials: fixtureCredentials()
            )
        }
    }

    func testResponseTooLarge() async throws {
        let (http, _) = makeHTTP()

        StubURLProtocol.respond = { _ in
            .init(
                status: 200,
                headers: ["Content-Length": "1025"],
                body: Self.jsonData(["ret": 0])
            )
        }
        await expectCode("response_too_large", name: "http.declaredLarge") {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue,
                path: "/x",
                responseLimit: 1024
            )
        }

        StubURLProtocol.respond = { _ in
            .init(
                status: 200,
                headers: [:],
                body: Data(repeating: 0x61, count: 1025)
            )
        }
        await expectCode("response_too_large", name: "http.bodyLarge") {
            _ = try await http.get(
                origin: XmlyOrigin.mobile.rawValue,
                path: "/x",
                responseLimit: 1024
            )
        }
    }

    func testFollowRedirectStopsAfterFour() async throws {
        let (http, _) = makeHTTP()
        StubURLProtocol.respond = { request in
            let next: String
            switch request.url?.path ?? "" {
            case "/start": next = "https://example.com/1"
            case "/1": next = "https://example.com/2"
            case "/2": next = "https://example.com/3"
            case "/3": next = "https://example.com/4"
            default: next = "https://example.com/end"
            }
            return .init(
                status: 302, headers: ["Location": next], body: Data()
            )
        }

        let final = await http.followRedirect(url: "https://example.com/start")
        XCTAssertEqual(final, "https://example.com/4", "http.redirectFinal")
        XCTAssertEqual(StubURLProtocol.requests.count, 4, "http.redirectCount")
    }

    func testFollowRedirectRewritesHTTPToHTTPS() async throws {
        let (http, _) = makeHTTP()
        StubURLProtocol.respond = { _ in
            .init(
                status: 302,
                headers: ["Location": "http://example.com/x"],
                body: Data()
            )
        }

        let final = await http.followRedirect(url: "https://example.com/start")
        XCTAssertEqual(final, "https://example.com/x", "http.redirectScheme")
    }

    func testCooldownKeepsLongerDeadline() async throws {
        let (http, fake) = makeHTTP()
        StubURLProtocol.respond = { request in
            if request.url?.path == "/a" {
                return .init(
                    status: 429,
                    headers: ["Retry-After": "30"],
                    body: Data()
                )
            }
            return .init(
                status: 429,
                headers: ["Retry-After": "2"],
                body: Data()
            )
        }

        // Two concurrent requests hit the same origin cooldown bucket;
        // whichever order they land in, the longer deadline must survive.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await http.get(
                    origin: XmlyOrigin.mobile.rawValue, path: "/a"
                )
            }
            group.addTask {
                _ = try? await http.get(
                    origin: XmlyOrigin.mobile.rawValue, path: "/b"
                )
            }
        }

        StubURLProtocol.respond = { _ in Self.ok(["ret": 0]) }
        let payload = try await http.get(
            origin: XmlyOrigin.mobile.rawValue, path: "/c"
        )
        XCTAssertEqual(payload["ret"] as? Int, 0, "http.cooldownAfter")
        XCTAssertEqual(fake.sleeps, [30], "http.cooldownKeepsLonger")
    }

    private func assertSame(
        _ actual: String,
        _ expected: String,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard actual == expected else {
            XCTFail(
                "\(name): values differ",
                file: file,
                line: line
            )
            return
        }
    }
}
