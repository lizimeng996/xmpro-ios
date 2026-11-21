import Foundation
import XCTest
@testable import XMPro

// 所有返回值与调用记录都由同一锁保护；处理闭包在锁内执行，不执行异步操作。
final class FakeHTTPTransport: HTTPTransport {
    struct Call {
        let method: String
        let origin: String
        let path: String
        let query: [String: String]
        let body: [String: Any]
        let form: [String: String]
        let authenticated: Bool
        let signed: Bool
        let readOnly: Bool
        let headers: [String: String]
        let responseLimit: Int?
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var redirects: [String] = []
    private let handler: (Call, Int) throws -> [String: Any]
    private let rawDataHandler: ((Call, Int) throws -> Data)?
    private let redirectResult: String

    init(
        redirectResult: String = "https://fixture.xmcdn.com/final.mp3",
        rawDataHandler: ((Call, Int) throws -> Data)? = nil,
        handler: @escaping (Call, Int) throws -> [String: Any]
    ) {
        self.handler = handler
        self.rawDataHandler = rawDataHandler
        self.redirectResult = redirectResult
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var redirectCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return redirects
    }

    private func invoke(_ call: Call) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return try handler(call, recorded.count)
    }

    private func invokeData(_ call: Call) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        if let rawDataHandler {
            return try rawDataHandler(call, recorded.count)
        }
        return try JSONSerialization.data(
            withJSONObject: handler(call, recorded.count),
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    func get(
        origin: String, path: String, query: [String: String],
        credentials: Credentials?, signed: Bool, readOnly: Bool,
        headers: [String: String], responseLimit: Int?
    ) async throws -> [String: Any] {
        try invoke(Call(
            method: "GET", origin: origin, path: path, query: query,
            body: [:], form: [:], authenticated: credentials != nil,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ))
    }

    func getData(
        origin: String, path: String, query: [String: String],
        credentials: Credentials?, signed: Bool, readOnly: Bool,
        headers: [String: String], responseLimit: Int?
    ) async throws -> Data {
        try invokeData(Call(
            method: "GET", origin: origin, path: path, query: query,
            body: [:], form: [:], authenticated: credentials != nil,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ))
    }

    func postJson(
        origin: String, path: String, query: [String: String],
        body: [String: Any], credentials: Credentials?,
        signed: Bool, readOnly: Bool, headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try invoke(Call(
            method: "JSON", origin: origin, path: path, query: query,
            body: body, form: [:], authenticated: credentials != nil,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ))
    }

    func postForm(
        origin: String, path: String, query: [String: String],
        form: [String: String], credentials: Credentials?,
        signed: Bool, readOnly: Bool, headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try invoke(Call(
            method: "FORM", origin: origin, path: path, query: query,
            body: [:], form: form, authenticated: credentials != nil,
            signed: signed, readOnly: readOnly, headers: headers,
            responseLimit: responseLimit
        ))
    }

    func followRedirect(url: String) async -> String {
        recordRedirect(url)
    }

    private func recordRedirect(_ url: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        redirects.append(url)
        return redirectResult
    }
}

// 断言只报告用例编号，不让 XCTest 自动展开凭据、摘要或请求字典。
func b1Check(
    _ condition: Bool,
    _ caseID: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(condition, caseID, file: file, line: line)
}

func b1ExpectError(
    _ code: String,
    _ caseID: String,
    definitive: Bool? = nil,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail(caseID)
    } catch let error as XmlyError {
        b1Check(error.code == code, caseID)
        if let definitive {
            b1Check(error.definitive == definitive, caseID)
        }
    } catch {
        XCTFail(caseID)
    }
}

enum B1Fixture {
    static let now: Int64 = 1_800_000_000_000

    static func clock() -> ServerClock {
        ServerClock(now: { Date(timeIntervalSince1970: Double(now) / 1000) })
    }

    static func context(_ uid: String = "101") throws -> AccountContext {
        AccountContext(credentials: try Credentials(
            token: uid + "&synthetic_fixture_only",
            deviceId: "synthetic-device-" + uid
        ))
    }

    static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func authorized(_ info: [String: Any]) throws -> [String: Any] {
        [
            "data": try XmlyCrypto.encrypt(
                json(["trackInfo": info]), key: XmlyCrypto.playKey
            )
        ]
    }

    static func quota(
        newDevice: Bool = false,
        remaining: Int? = 60,
        timestamp: Int64 = now
    ) throws -> [String: Any] {
        var data: [String: Any] = [
            "newDevice": try XmlyCrypto.encrypt(
                "\(newDevice ? "true" : "false")|\(timestamp)",
                key: XmlyCrypto.durationKey
            )
        ]
        if let remaining {
            data["availableListenDuration"] = try XmlyCrypto.encrypt(
                "\(remaining)|\(timestamp)", key: XmlyCrypto.durationKey
            )
        }
        return ["data": data]
    }

    static func track(
        _ id: Int = 1,
        order: Int? = nil,
        album: Int = 7
    ) -> [String: Any] {
        var raw: [String: Any] = [
            "trackId": id, "albumId": album, "title": "合成声音",
            "albumTitle": "合成专辑", "duration": 120,
            "isPaid": false
        ]
        if let order { raw["orderNo"] = order }
        return raw
    }

    static func catalogue(
        rows: [[String: Any]],
        total: Int? = nil,
        page: Int = 1,
        size: Int = 2
    ) -> [String: Any] {
        [
            "data": [
                "totalCount": total ?? rows.count,
                "pageId": page, "pageSize": size, "list": rows
            ] as [String: Any]
        ]
    }
}

final class XmlyClientServiceTests: XCTestCase {
    func testSearchKindsAndBoundedDocs() async throws {
        for kind in ["track", "album"] {
            let fake = FakeHTTPTransport { _, _ in
                [
                    "ret": 200,
                    "data": ["result": ["response": [
                        "numFound": 91,
                        "docs": [
                            ["trackId": 1, "albumId": 7, "title": "甲"],
                            ["trackId": 2, "albumId": 8, "title": "乙"],
                            ["trackId": 3, "albumId": 9, "title": "丙"]
                        ]
                    ]]]
                ]
            }
            let client = XmlyClientService(http: fake, accountContext: nil)
            let page = try await client.search(
                query: " 合成 ", kind: kind, page: 2, pageSize: 2
            )
            b1Check(page.total == 91 && page.page == 2, "search-total")
            b1Check(
                kind == "track"
                    ? page.tracks.count == 2 && page.albums.isEmpty
                    : page.albums.count == 2 && page.tracks.isEmpty,
                "search-kind"
            )
            b1Check(fake.calls.first?.query["kw"] == "合成", "search-query")
            b1Check(
                fake.calls.first?.origin == XmlyOrigin.search.rawValue,
                "search-origin"
            )
            b1Check(fake.calls.first?.authenticated == false, "search-anonymous")
        }
    }

    func testSearchValidation() async {
        let fake = FakeHTTPTransport { _, _ in [:] }
        let client = XmlyClientService(http: fake, accountContext: nil)
        for (query, kind) in [
            (" \n", "track"), (String(repeating: "字", count: 201), "track"),
            ("关键词", "user")
        ] {
            await b1ExpectError("invalid_search", "search-invalid", definitive: true) {
                _ = try await client.search(query: query, kind: kind)
            }
        }
        b1Check(fake.calls.isEmpty, "search-no-request")
    }

    func testAlbumStrictValidation() async {
        let normal = [B1Fixture.track(1, order: 1), B1Fixture.track(2, order: 2)]
        var wrongPage = B1Fixture.catalogue(rows: normal)
        var pageData = wrongPage["data"] as? [String: Any] ?? [:]
        pageData["pageId"] = 2
        wrongPage["data"] = pageData

        var wrongHeader = B1Fixture.catalogue(rows: normal)
        wrongHeader["album"] = ["albumId": 8]

        var conflict = B1Fixture.track(1, order: 1)
        conflict["orderNum"] = 2

        let cases: [([String: Any], String)] = [
            (wrongPage, "invalid_catalogue"),
            (B1Fixture.catalogue(rows: [], total: 2), "incomplete_catalogue"),
            (B1Fixture.catalogue(rows: [normal[0], normal[0]]), "duplicate_page"),
            (B1Fixture.catalogue(rows: [
                B1Fixture.track(1, album: 8), normal[1]
            ]), "id_mismatch"),
            (wrongHeader, "id_mismatch")
        ]
        for (payload, code) in cases {
            let fake = FakeHTTPTransport { _, _ in payload }
            let client = XmlyClientService(http: fake, accountContext: nil)
            await b1ExpectError(code, "album-strict") {
                _ = try await client.album(albumId: "7", pageSize: 2)
            }
        }

        // 上游 d70b270：滞后的 totalCount 与冲突/乱序的 order 字段不再导致整页崩溃。
        for tolerant in [
            B1Fixture.catalogue(rows: [normal[0]], total: 2),
            B1Fixture.catalogue(rows: [B1Fixture.track(1, order: 2), B1Fixture.track(2, order: 1)]),
            B1Fixture.catalogue(rows: [conflict, normal[1]])
        ] {
            let fake = FakeHTTPTransport { _, _ in tolerant }
            let client = XmlyClientService(http: fake, accountContext: nil)
            let page = try? await client.album(albumId: "7", pageSize: 2)
            XCTAssertNotNil(page)
        }
    }

    func testAlbumPositionsFallbackAndDetailFailure() async throws {
        for ascending in [true, false] {
            let rows = ascending
                ? [B1Fixture.track(3, order: 3), B1Fixture.track(4, order: 4)]
                : [B1Fixture.track(3, order: 3), B1Fixture.track(2, order: 2)]
            let payload = B1Fixture.catalogue(rows: rows, total: 5, page: 2)
            let fake = FakeHTTPTransport { call, _ in
                if call.path == "/mobile-album/album/detail" {
                    throw XmlyError.failure(code: .network, message: "fixture")
                }
                return payload
            }
            let client = XmlyClientService(http: fake, accountContext: nil)
            let page = try await client.album(
                albumId: "7", page: 2, pageSize: 2, ascending: ascending
            )
            b1Check(page.album.title == "合成专辑", "album-title-fallback")
            b1Check(page.total == 5 && page.tracks.count == 2, "album-normal")
            let positions = page.tracks.map {
                // raw 值经 CatalogueValue 还原为 Int64，须经 NSNumber 桥接取值；
                // 直接 as? Int 对 Int64 恒为 nil。
                (($0.raw["officialPosition"] ?? nil) as? NSNumber)?.intValue
            }
            b1Check(
                positions == (ascending ? [3, 4] : [3, 2]),
                "album-positions"
            )
        }
    }

    func testAlbumDetailMerge() async throws {
        let fake = FakeHTTPTransport { call, _ in
            if call.path == "/mobile-album/album/detail" {
                return ["data": [
                    "album": ["title": "详情标题"],
                    "user": ["nickname": "合成主播", "avatar": "https://example.invalid/a"],
                    "detail": ["intro": "合成简介"]
                ]]
            }
            return B1Fixture.catalogue(rows: [B1Fixture.track()], size: 1)
        }
        let client = XmlyClientService(http: fake, accountContext: nil)
        let page = try await client.album(albumId: "7", pageSize: 1)
        b1Check(
            page.album.title == "详情标题"
                && page.album.artist == "合成主播"
                && page.album.intro == "合成简介",
            "album-detail"
        )
    }

    func testCommentsClampAndSkipEmpty() async throws {
        let fake = FakeHTTPTransport { _, _ in
            [
                "ret": 200,
                "data": [
                    "currentPage": 2, "totalPage": 3, "totalComment": 9,
                    "comments": [
                        ["id": 1, "content": " \n"],
                        [
                            "id": 2, "uid": 3, "content": " 合成评论 ",
                            "smallHeader": "//fixture.xmcdn.com/avatar",
                            "replies": [
                                ["content": "回复", "replies": [["content": "第三层"]]]
                            ]
                        ]
                    ]
                ]
            ]
        }
        let client = XmlyClientService(http: fake, accountContext: nil)
        let page = try await client.trackComments(number: "1", pageSize: 100)
        b1Check(fake.calls.first?.query["pageSize"] == "30", "comments-size")
        b1Check(
            fake.calls.first?.origin == XmlyOrigin.search.rawValue
                && fake.calls.first?.authenticated == false,
            "comments-origin"
        )
        b1Check(
            page.comments.count == 1 && page.comments.first?.content == "合成评论"
                && page.page == 2 && page.totalPages == 3 && page.total == 9,
            "comments-page"
        )
        b1Check(
            page.comments.first?.replies.first?.replies.first?.content == "第三层",
            "comments-depth"
        )
    }

    func testParseCaptionsHandlesTimedLRCAndHTMLFallback() {
        let lrc = """
        [00:01.50]第一句台词
        [00:10.00][00:20.25]重复出现的句子
        """
        let timed = XmlyClientService.parseCaptions(lyric: lrc, richIntro: "", intro: "")
        XCTAssertTrue(timed.isTimed)
        XCTAssertEqual(timed.lines.count, 3)
        XCTAssertEqual(timed.lines[0].timeMs, 1_500)
        XCTAssertEqual(timed.lines[0].text, "第一句台词")
        XCTAssertEqual(timed.activeLineIndex(at: 1_499), nil)
        XCTAssertEqual(timed.activeLineIndex(at: 1_500), 0)
        XCTAssertEqual(timed.activeLineIndex(at: 15_000), 1)
        XCTAssertEqual(timed.activeLineIndex(at: 21_000), 2)

        let html = XmlyClientService.parseCaptions(
            lyric: "",
            richIntro: "<p>第一章&nbsp;风起</p><br /><div>第二段内容</div>",
            intro: ""
        )
        XCTAssertFalse(html.isTimed)
        XCTAssertEqual(html.sourceLabel, "声音文稿")
        XCTAssertEqual(html.lines.map(\.text), ["第一章 风起", "第二段内容"])
    }

    func testAnonymousResolveSelectionAndRedirect() async throws {
        var info = B1Fixture.track()
        info["playUrl64"] = try XmlyCrypto.encrypt(
            "https://fixture.xmcdn.com/64.mp3", key: XmlyCrypto.playKey
        )
        info["playUrl32"] = "https://example.invalid/32"
        let fake = FakeHTTPTransport { _, _ in ["data": info] }
        let client = XmlyClientService(http: fake, accountContext: nil)
        let automatic = try await client.resolve(number: "1")
        b1Check(automatic.actualQuality == "mp3_64", "resolve-auto")
        b1Check(!automatic.requiresReward, "resolve-free")
        b1Check(fake.redirectCalls.isEmpty, "resolve-cdn")
        let selected = try await client.resolve(number: "1", quality: "mp3_32")
        b1Check(selected.actualQuality == "mp3_32", "resolve-selected")
        b1Check(fake.redirectCalls.count == 1, "resolve-redirect")
        b1Check(selected.url.hasSuffix("/final.mp3"), "resolve-final")
    }

    func testAuthenticatedListAndQualityOrder() async throws {
        var info = B1Fixture.track()
        info["playUrlList"] = try B1Fixture.json([
            ["type": "mp3_32", "url": "https://fixture.xmcdn.com/32"],
            ["type": "m4a_64", "url": "https://fixture.xmcdn.com/64"],
            ["type": "m4a_128", "url": "https://fixture.xmcdn.com/128"],
            ["type": "unknown", "url": "invalid"]
        ])
        let payload = try B1Fixture.authorized(info)
        let fake = FakeHTTPTransport { _, _ in payload }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context()
        )
        let automatic = try await client.resolve(number: "1")
        let selected = try await client.resolve(number: "1", quality: "m4a_64")
        b1Check(automatic.actualQuality == "m4a_128", "resolve-list-order")
        b1Check(selected.actualQuality == "m4a_64", "resolve-list-selection")
        b1Check(fake.calls.allSatisfy(\.signed), "resolve-signed")
    }

    func testAuthenticatedListDoesNotOverrideDirectUrls() async throws {
        // 与 Kotlin 一致：playUrl64／32 总是先加，列表同类型不覆盖直链值。
        var info = B1Fixture.track()
        info["playUrl64"] = try XmlyCrypto.encrypt(
            "https://fixture.xmcdn.com/direct64", key: XmlyCrypto.playKey
        )
        info["playUrl32"] = try XmlyCrypto.encrypt(
            "https://fixture.xmcdn.com/direct32", key: XmlyCrypto.playKey
        )
        info["playUrlList"] = try B1Fixture.json([
            ["type": "mp3_64", "url": "https://fixture.xmcdn.com/list64"],
            ["type": "mp3_32", "url": "https://fixture.xmcdn.com/list32"]
        ])
        let payload = try B1Fixture.authorized(info)
        let fake = FakeHTTPTransport { _, _ in payload }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context()
        )
        let automatic = try await client.resolve(number: "1")
        b1Check(automatic.url.hasSuffix("/direct64"), "resolve-direct-precedence")
        b1Check(automatic.actualQuality == "mp3_64", "resolve-direct-quality")
    }

    func testResolveErrors() async throws {
        var paid = B1Fixture.track()
        paid["isPaid"] = true
        let anonymous = XmlyClientService(
            http: FakeHTTPTransport { _, _ in ["data": paid] },
            accountContext: nil
        )
        await b1ExpectError("login_required", "resolve-login") {
            _ = try await anonymous.resolve(number: "1")
        }
        await b1ExpectError("invalid_quality", "resolve-quality", definitive: true) {
            _ = try await anonymous.resolve(number: "1", quality: "lossless")
        }

        let paidPayload = try B1Fixture.authorized(paid)
        let zero = try B1Fixture.quota(remaining: 0)
        let quotaFake = FakeHTTPTransport { call, _ in
            call.path.hasSuffix("/config") ? zero : paidPayload
        }
        let paidClient = XmlyClientService(
            http: quotaFake, accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        await b1ExpectError("insufficient_quota", "resolve-quota") {
            _ = try await paidClient.resolve(number: "1")
        }

        for (field, value, code) in [
            ("isPreview", true as Any, "preview_only"),
            ("isTrial", true as Any, "preview_only"),
            ("playUrlList", "invalid" as Any, "invalid_media"),
            ("playUrlList", 17 as Any, "invalid_media"),
            ("playUrlList", [] as [Any], "permission_denied")
        ] {
            var info = B1Fixture.track()
            info[field] = value
            let payload = try B1Fixture.authorized(info)
            let client = XmlyClientService(
                http: FakeHTTPTransport { _, _ in payload },
                accountContext: try B1Fixture.context()
            )
            await b1ExpectError(code, "resolve-invalid-response") {
                _ = try await client.resolve(number: "1")
            }
        }
    }

    func testRewardRefreshAndBalanceClamp() async throws {
        var paid = B1Fixture.track()
        paid["isPaid"] = true
        let initial = try B1Fixture.authorized(paid)
        paid["playUrlList"] = [
            ["type": "mp3_64", "url": "https://fixture.xmcdn.com/paid"]
        ]
        let refreshed = try B1Fixture.authorized(paid)
        let quota = try B1Fixture.quota(remaining: 100_000)
        let fake = FakeHTTPTransport { call, index in
            if call.path.hasSuffix("/config") { return quota }
            return index == 1 ? initial : refreshed
        }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        let audio = try await client.resolve(number: "1")
        b1Check(audio.requiresReward, "reward-obligation")
        guard let encrypted = fake.calls.last?.body["data"] as? String else {
            XCTFail("reward-body")
            return
        }
        let plain = try XmlyCrypto.decrypt(encrypted, key: XmlyCrypto.playKey)
        let object = try JSONSerialization.jsonObject(
            with: Data(plain.utf8)
        ) as? [String: Any]
        b1Check(object?["a1"] as? String == "86400", "reward-clamp")
        b1Check(object?["a2"] as? String == String(B1Fixture.now), "reward-time")
        b1Check(object?["a3"] as? String == "0", "reward-a3")
    }

    func testQuotaConfigStaleAndNewDevice() async throws {
        for (newDevice, remaining) in [(false, Optional(63)), (true, nil)] {
            let payload = try B1Fixture.quota(
                newDevice: newDevice, remaining: remaining
            )
            let fake = FakeHTTPTransport { _, _ in payload }
            let client = XmlyClientService(
                http: fake, accountContext: try B1Fixture.context(),
                clock: B1Fixture.clock()
            )
            let quota = try await client.quota()
            b1Check(
                quota.newDevice == newDevice
                    && quota.remainingSeconds == (remaining ?? 0),
                "quota-config"
            )
            b1Check(
                fake.calls.first?.method == "JSON"
                    && fake.calls.first?.readOnly == true
                    && fake.calls.first?.body["uid"] == nil,
                "quota-request"
            )
        }
        let stale = try B1Fixture.quota(
            timestamp: B1Fixture.now - ProtocolConfig.listeningValidityMs
        )
        let client = XmlyClientService(
            http: FakeHTTPTransport { _, _ in stale },
            accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        await b1ExpectError("invalid_quota", "quota-stale") {
            _ = try await client.quota()
        }
        await b1ExpectError("invalid_duration", "debit-zero", definitive: true) {
            _ = try await client.debit(seconds: 0)
        }
    }

    func testDebitUsesJSONAndReportDoesNotRequireNewDevice() async throws {
        let balance = try XmlyCrypto.encrypt(
            "50|\(B1Fixture.now)", key: XmlyCrypto.durationKey
        )
        let fake = FakeHTTPTransport { _, _ in
            ["data": ["availableListenDuration": balance]]
        }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        let quota = try await client.debit(seconds: 10)
        b1Check(quota.remainingSeconds == 50 && !quota.newDevice, "debit-result")
        b1Check(
            fake.calls.first?.method == "JSON"
                && fake.calls.first?.readOnly == false
                && fake.calls.first?.body["duration"] as? String == "10",
            "debit-request"
        )
    }

    func testRequestAuthenticationHeadersAndLimit() async throws {
        let fake = FakeHTTPTransport { _, _ in [:] }
        let anonymous = XmlyClientService(http: fake, accountContext: nil)
        await b1ExpectError("login_required", "request-login") {
            _ = try await anonymous.request(
                method: "GET", origin: XmlyOrigin.mobile.rawValue, path: "/fixture"
            )
        }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context()
        )
        for method in ["GET", "JSON", "FORM"] {
            _ = try await client.request(
                method: method == "GET" ? "GET" : "POST",
                origin: XmlyOrigin.collector.rawValue, path: "/fixture",
                form: method == "FORM" ? ["fixture": "1"] : nil,
                json: ["fixture": 1],
                signed: true, headers: ["Accept": "application/json"]
            )
        }
        b1Check(
            fake.calls.allSatisfy {
                $0.responseLimit == 8 * 1024 * 1024
                    && $0.headers["User-Agent"] == ProtocolConfig.collectorUserAgent
                    && $0.headers["Accept"] == "application/json"
            },
            "request-collector"
        )
        b1Check(fake.calls.last?.signed == false, "request-form-signing")
        _ = try await client.request(
            method: "GET", origin: XmlyOrigin.mobile.rawValue, path: "/fixture"
        )
        b1Check(fake.calls.last?.responseLimit == nil, "request-default-limit")
    }
}
