
import XCTest
import Foundation
@testable import XMPro

private actor ShelfTransport: HTTPTransport {
    struct Call {
        let method: String
        let path: String
        let query: [String: String]
        let form: [String: String]?
        let readOnly: Bool
        let authenticated: Bool
    }

    private var responses: [[String: Any]] = []
    private var recorded: [Call] = []

    func append(_ values: [[String: Any]]) {
        responses.append(contentsOf: values)
    }

    func calls() -> [Call] { recorded }

    private func take(
        method: String,
        path: String,
        query: [String: String],
        form: [String: String]?,
        credentials: Credentials?,
        readOnly: Bool
    ) throws -> [String: Any] {
        recorded.append(Call(
            method: method, path: path, query: query, form: form,
            readOnly: readOnly, authenticated: credentials != nil
        ))
        guard !responses.isEmpty else { throw B1JSON.error(.invalidResponse) }
        return responses.removeFirst()
    }

    func get(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try take(
            method: "GET", path: path, query: query, form: nil,
            credentials: credentials, readOnly: readOnly
        )
    }

    func getData(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> Data {
        let object = try take(
            method: "GET", path: path, query: query, form: nil,
            credentials: credentials, readOnly: readOnly
        )
        return try JSONSerialization.data(withJSONObject: object)
    }

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
    ) async throws -> [String: Any] {
        try take(
            method: "POST", path: path, query: query, form: nil,
            credentials: credentials, readOnly: readOnly
        )
    }

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
    ) async throws -> [String: Any] {
        try take(
            method: "POST", path: path, query: query, form: form,
            credentials: credentials, readOnly: readOnly
        )
    }

    func followRedirect(url: String) async -> String { url }
}

final class XmlyExperienceServiceTests: XCTestCase {
    private func fixture(
        authenticated: Bool = true
    ) throws -> (XmlyExperienceService, ShelfTransport) {
        let transport = ShelfTransport()
        let credentials = try Credentials(
            token: "7&fixture-token", deviceId: "fixture-device"
        )
        let client = XmlyClientService(
            http: transport,
            accountContext: authenticated ? AccountContext(credentials: credentials) : nil,
            clock: .shared
        )
        return (XmlyExperienceService(client: client), transport)
    }

    private func albumRow(_ id: Int = 1) -> [String: Any] {
        [
            "albumId": id, "albumTitle": "专辑", "nickname": "主播",
            "albumIntro": "简介", "albumCover": "http://a.xmcdn.com/cover",
            "trackCount": "12", "trackTitle": "最新声音",
            "unreadNum": "2", "lastUpdateAt": 100
        ]
    }

    private func trackRow(_ id: Int = 1, timeline: Int64 = 100) -> [String: Any] {
        [
            "trackId": id, "albumId": 8, "title": "声音",
            "nickname": "主播", "albumTitle": "专辑", "duration": "12.5",
            "paid": true, "authorized": false,
            "cover": "http://a.xmcdn.com/cover",
            "resourceType": 1, "timeline": timeline
        ]
    }

    private func expect(
        _ code: XmlyError.Code,
        definitive: Bool = true,
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

    func testSubscriptionsParsingAndQuery() async throws {
        let (service, transport) = try fixture()
        await transport.append([["data": [
            "albumResults": ["list": [albumRow()]], "hasMore": false
        ]]])
        let result = try await service.subscriptions()
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.album.id, "1")
        XCTAssertEqual(result.items.first?.album.total, 12)
        XCTAssertEqual(result.items.first?.album.intro, "简介")
        XCTAssertEqual(result.items.first?.album.coverUrl, "https://a.xmcdn.com/cover")
        XCTAssertEqual(result.items.first?.unreadCount, 2)
        XCTAssertEqual(result.items.first?.updatedAt, 100)
        XCTAssertFalse(result.hasMore)
        let calls = await transport.calls()
        XCTAssertTrue(calls[0].path.hasPrefix("/fsubscribe-web/subscribe/comprehensive/rank/"))
        XCTAssertEqual(calls[0].query, ["pageId": "1", "sign": "2", "size": "30"])
        XCTAssertTrue(calls[0].authenticated)
    }

    func testSubscriptionsDuplicatesAndMissingFields() async throws {
        let (service, transport) = try fixture()
        await transport.append([["data": [
            "albumResults": [albumRow(), albumRow()], "hasMore": false
        ]]])
        await expect(.repeatedPage, definitive: false) {
            _ = try await service.subscriptions()
        }
        var missingAlbumId = albumRow()
        missingAlbumId.removeValue(forKey: "albumId")
        await transport.append([["data": ["albumResults": [missingAlbumId]]]])
        let skipped = try await service.subscriptions()
        XCTAssertTrue(skipped.items.isEmpty)

        var missingUnread = albumRow()
        missingUnread.removeValue(forKey: "unreadNum")
        await transport.append([["data": ["albumResults": [missingUnread]]]])
        let defaulted = try await service.subscriptions()
        XCTAssertEqual(defaulted.items.first?.unreadCount, 0)

        await transport.append([[:]])
        await expect(.invalidHome) { _ = try await service.subscriptions() }
    }

    func testSubscriptionsHasMoreAndRowLimit() async throws {
        let (service, transport) = try fixture()
        await transport.append([["data": ["albumResults": [albumRow()]]]])
        let result = try await service.subscriptions(pageSize: 1)
        XCTAssertTrue(result.hasMore)

        await transport.append([["data": ["albumResults": [], "hasMore": true]]])
        await expect(.invalidHome) { _ = try await service.subscriptions() }

        await transport.append([["data": [
            "albumResults": Array(repeating: albumRow(), count: 501)
        ]]])
        await expect(.invalidHome) { _ = try await service.subscriptions() }
    }

    func testFavoritesParsingAndFallbackKeys() async throws {
        let (service, transport) = try fixture()
        var row = trackRow()
        row["trackId"] = ""
        row["id"] = 2
        row["albumId"] = ""
        row["album_id"] = 8
        await transport.append([["data": [
            "maxPageId": 1, "pageId": 1, "pageSize": 30, "dataList": [row]
        ]]])
        let result = try await service.favorites()
        XCTAssertEqual(result.items.first?.id, "xmly:2")
        XCTAssertEqual(result.items.first?.albumKey, "8")
        XCTAssertEqual(result.items.first?.duration, 12.5)
        XCTAssertEqual(result.items.first?.isPaid, true)
        XCTAssertEqual(result.items.first?.isAuthorized, false)
        XCTAssertEqual(result.items.first?.coverUrl, "https://a.xmcdn.com/cover")
        XCTAssertFalse(result.hasMore)
        let calls = await transport.calls()
        XCTAssertEqual(calls[0].path, "/lite-mobile/like/v1/user-likes")
        XCTAssertEqual(calls[0].query, ["pageId": "1", "pageSize": "30"])
    }

    func testDurationStringJvmParsing() async throws {
        // JVM `toDoubleOrNull` 接受首尾空白与 f/d 后缀；Swift `Double` 不接受。
        let cases: [(String, Double)] = [
            ("12.5", 12.5),
            ("12.5f", 12.5),
            ("12.5F", 12.5),
            ("12.5d", 12.5),
            ("  12.5  ", 12.5),
            ("1e3f", 1000),
            ("abc", 0),
            ("12.5ff", 0),
            ("inf", 0),
            ("", 0),
            // 带符号 NaN 加后缀：JVM 不接受（后缀只用于数值字面量），回退 0。
            ("NaNf", 0),
            ("+NaNf", 0),
            ("-NaND", 0),
            ("+nanf", 0)
        ]
        for (text, expected) in cases {
            let (service, transport) = try fixture()
            var row = trackRow()
            row["duration"] = text
            await transport.append([["data": [
                "maxPageId": 1, "pageId": 1, "pageSize": 30, "dataList": [row]
            ]]])
            let result = try await service.favorites()
            XCTAssertEqual(result.items.first?.duration, expected)
        }
        // NaN / Infinity：JVM 接受为特殊值，Track 构造出于 JSON 安全性拒绝非有限时长，书架容错跳过该脏行。
        for text in ["NaN", "Infinity", "-Infinity"] {
            let parsed = try XCTUnwrap(B1JSON.jvmDouble(text))
            XCTAssertTrue(parsed.isNaN || parsed.isInfinite)
            let (service, transport) = try fixture()
            var row = trackRow()
            row["duration"] = text
            await transport.append([["data": [
                "maxPageId": 1, "pageId": 1, "pageSize": 30, "dataList": [row]
            ]]])
            let result = try await service.favorites()
            XCTAssertTrue(result.items.isEmpty)
        }
    }

    func testStampUsesSystemTime() async throws {
        // 路径时间戳与 Kotlin 一致：系统 Unix 毫秒（非 ServerClock 校正时间）。
        let (service, transport) = try fixture()
        await transport.append([["data": [
            "albumResults": [albumRow()], "hasMore": false
        ]]])
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        _ = try await service.subscriptions()
        let after = Int64(Date().timeIntervalSince1970 * 1000)
        let calls = await transport.calls()
        let stampText = try XCTUnwrap(calls[0].path.split(separator: "/").last.map(String.init))
        let stamp = try XCTUnwrap(Int64(stampText))
        XCTAssertTrue(stamp >= before - 1000 && stamp <= after + 1000)
    }

    func testFavoritesEchoAndPageBounds() async throws {
        // 上游 10e06f9：收藏接口回显分页字段不具权威性，容忍页码偏差。
        let (service, transport) = try fixture()
        await transport.append([["data": ["maxPageId": 2, "pageId": 2, "dataList": [trackRow()]]]])
        let page = try await service.favorites(page: 1)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertTrue(page.hasMore)
    }

    func testFavoritesTypeAlbumAndDuplicates() async throws {
        let (service, transport) = try fixture()
        var wrongType = trackRow()
        wrongType["resourceType"] = 2
        var missingAlbum = trackRow()
        missingAlbum.removeValue(forKey: "albumId")
        for row in [wrongType, missingAlbum] {
            await transport.append([["data": ["maxPageId": 1, "dataList": [row]]]])
            let page = try await service.favorites()
            XCTAssertTrue(page.items.isEmpty)
        }
        await transport.append([["data": [
            "maxPageId": 1, "dataList": [trackRow(), trackRow()]
        ]]])
        await expect(.repeatedPage, definitive: false) {
            _ = try await service.favorites()
        }
    }

    func testUpdatesParsingAndCursorQuery() async throws {
        let (service, transport) = try fixture()
        var first = trackRow(1, timeline: 100)
        first["createdAt"] = 120
        await transport.append([["data": [
            "trackResults": [first, trackRow(2, timeline: 90)], "hasMore": true
        ]]])
        let result = try await service.updates(before: 200)
        XCTAssertEqual(result.items.map(\.publishedAt), [120, 90])
        XCTAssertEqual(result.nextTimeline, 90)
        XCTAssertTrue(result.hasMore)
        let calls = await transport.calls()
        XCTAssertTrue(calls[0].path.hasPrefix("/track-feed/v1/track-feed/dynamic/ts-"))
        XCTAssertEqual(calls[0].query, ["sign": "2", "size": "30", "timeline": "200"])
    }

    func testUpdatesMonotonicityAndDuplicates() async throws {
        let (service, transport) = try fixture()
        await transport.append([["data": [
            "trackResults": [trackRow(1, timeline: 90), trackRow(2, timeline: 100)],
            "hasMore": false
        ]]])
        let skippedOutOfOrder = try await service.updates()
        XCTAssertEqual(skippedOutOfOrder.items.count, 1)

        await transport.append([["data": [
            "trackResults": [trackRow(), trackRow()], "hasMore": false
        ]]])
        await expect(.repeatedPage, definitive: false) {
            _ = try await service.updates()
        }

        await transport.append([["data": [
            "trackResults": [trackRow(1), trackRow(2)], "hasMore": false
        ]]])
        let equal = try await service.updates()
        XCTAssertEqual(equal.items.count, 2)
    }

    func testUpdatesStrictHasMoreAndBefore() async throws {
        let (service, transport) = try fixture()
        for value: Any in ["true", 1, NSNull()] {
            await transport.append([["data": ["trackResults": [], "hasMore": value]]])
            await expect(.invalidHome) { _ = try await service.updates() }
        }
        await transport.append([["data": ["trackResults": []]]])
        await expect(.invalidHome) { _ = try await service.updates() }

        for before: Int64 in [0, -1, 2_115_354_119_001] {
            await expect(.invalidHome) { _ = try await service.updates(before: before) }
        }
        await transport.append([["data": [
            "trackResults": [trackRow()], "hasMore": false
        ]]])
        await expect(.repeatedPage, definitive: false) {
            _ = try await service.updates(before: 100)
        }
        for rows in [[], [trackRow(1, timeline: 0)]] {
            await transport.append([["data": ["trackResults": rows, "hasMore": true]]])
            let page = try await service.updates()
            XCTAssertFalse(page.hasMore)
        }
    }

    func testPagingAndAnonymousAccess() async throws {
        let (service, _) = try fixture()
        await expect(.invalidPage) { _ = try await service.subscriptions(page: 0) }
        await expect(.invalidPage) { _ = try await service.favorites(page: 10_001) }
        await expect(.invalidPage) { _ = try await service.updates(pageSize: 51) }
        await expect(.invalidPage) { _ = try await service.subscriptions(pageSize: 0) }

        let (anonymous, transport) = try fixture(authenticated: false)
        let track = try Track(rawId: "1", albumId: "8")
        await expect(.loginRequired) { _ = try await anonymous.subscriptions() }
        await expect(.loginRequired) { _ = try await anonymous.favorites() }
        await expect(.loginRequired) { _ = try await anonymous.updates() }
        await expect(.loginRequired) {
            try await anonymous.setSubscribed(albumId: "8", subscribed: true)
        }
        await expect(.loginRequired) {
            try await anonymous.setFavorite(track: track, favorite: true)
        }
        let calls = await transport.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testSetSubscribedPathsFormsAndRet() async throws {
        let (service, transport) = try fixture()
        await transport.append([["ret": 200], ["ret": "0"], ["ret": 791]])
        try await service.setSubscribed(albumId: "xmly:8", subscribed: true)
        try await service.setSubscribed(albumId: "8", subscribed: false)
        await expect(.invalidHome) {
            try await service.setSubscribed(albumId: "8", subscribed: true)
        }
        let calls = await transport.calls()
        XCTAssertEqual(calls[0].path, "/revision/subscription/setSubscriptionAlbum")
        XCTAssertEqual(calls[1].path, "/revision/subscription/cancelSubscriptionAlbum")
        XCTAssertTrue(calls.allSatisfy {
            $0.method == "POST" && !$0.readOnly && $0.form == ["albumId": "8"]
        })
    }

    func testSetFavoritePathsFormsAndAlbumLookup() async throws {
        let (service, transport) = try fixture()
        let track = try Track(rawId: "1", albumId: "8")
        await transport.append([["ret": 0], ["ret": 0]])
        try await service.setFavorite(track: track, favorite: true)
        try await service.setFavorite(track: track, favorite: false)

        // 账号 track 查询返回加密 trackInfo，fixture 自带完整协议形状。
        let info = try B1JSON.encode(["trackInfo": ["trackId": "1", "albumId": "8"]])
        let encrypted = try XmlyCrypto.encrypt(info, key: XmlyCrypto.playKey)
        await transport.append([["data": encrypted], ["ret": 0]])
        try await service.setFavorite(track: Track(rawId: "1"), favorite: true)

        let calls = await transport.calls()
        XCTAssertEqual(calls[0].path, "/lite-mobile/like/v1/like")
        XCTAssertEqual(calls[1].path, "/lite-mobile/like/v1/dislike")
        XCTAssertEqual(calls[2].path, "/fmobile-track/fmobile/track/v2/baseInfo")
        for index in [0, 1, 3] {
            XCTAssertEqual(
                calls[index].form,
                ["resourceId": "1", "albumId": "8", "resourceType": "1"]
            )
            XCTAssertFalse(calls[index].readOnly)
        }
    }

    func testSetFavoriteMissingAlbumAndRejectedRet() async throws {
        let (service, transport) = try fixture()
        let info = try B1JSON.encode(["trackInfo": ["trackId": "1"]])
        let encrypted = try XmlyCrypto.encrypt(info, key: XmlyCrypto.playKey)
        await transport.append([["data": encrypted]])
        await expect(.missingAlbum) {
            try await service.setFavorite(track: Track(rawId: "1"), favorite: true)
        }

        await transport.append([["ret": 1]])
        await expect(.invalidHome) {
            try await service.setFavorite(
                track: Track(rawId: "1", albumId: "8"), favorite: true
            )
        }
    }
}
