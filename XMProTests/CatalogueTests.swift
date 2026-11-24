import Foundation
import XCTest
@testable import XMPro

// 本轮仅交付代码文本；以下测试需由执行侧在 Apple 测试环境验证。
final class CatalogueTests: XCTestCase {
    // MARK: - xmlyIdentifier

    func testIdentifierAcceptsBareAndPrefixed() throws {
        XCTAssertEqual(try xmlyIdentifier("123"), "123", "id_bare")
        XCTAssertEqual(try xmlyIdentifier("xmly:123"), "123", "id_prefixed")
        XCTAssertEqual(
            try xmlyIdentifier("9999999999999999999"), "9999999999999999999", "id_19_digits"
        )
    }

    func testIdentifierRejectsInvalid() {
        for value in ["", "0", "0123", "xmly:", "abc", "12a", "xmly:0", "-5", " 123"] {
            XCTAssertThrowsError(try xmlyIdentifier(value), "id_invalid_\(value)") { error in
                guard let xmly = error as? XmlyError else {
                    return XCTFail("id_invalid_type_\(value)")
                }
                XCTAssertEqual(xmly.code, "invalid_id", "id_invalid_code_\(value)")
                XCTAssertTrue(xmly.definitive, "id_invalid_definitive_\(value)")
            }
        }
    }

    // MARK: - xmlyPositive

    func testPositiveAcceptsStringAndInt() {
        XCTAssertEqual(xmlyPositive("42"), 42, "positive_string")
        XCTAssertEqual(xmlyPositive(NSNumber(value: 42)), 42, "positive_number")
        XCTAssertEqual(xmlyPositive(7), 7, "positive_int")
    }

    func testPositiveRejectsOutOfRangeAndNonIntegers() {
        XCTAssertNil(xmlyPositive("0"), "positive_zero")
        XCTAssertNil(xmlyPositive("-1"), "positive_negative")
        XCTAssertNil(xmlyPositive("12a"), "positive_digits")
        XCTAssertNil(xmlyPositive(""), "positive_empty")
        XCTAssertNil(xmlyPositive(NSNumber(value: true)), "positive_bool")
        XCTAssertNil(xmlyPositive(NSNumber(value: 1.5)), "positive_double")
        // Kotlin 上界 Int.MAX_VALUE；超限的 64 位数值同样返回 nil。
        XCTAssertNil(xmlyPositive("5000000000"), "positive_over_int32")
        XCTAssertNil(
            xmlyPositive(NSNumber(value: Int64(5_000_000_000))), "positive_over_int64"
        )
        XCTAssertNil(xmlyPositive(nil), "positive_nil")
    }

    // MARK: - mediaUri / coverUrl

    func testMediaUriUpgradesTrustedHttp() throws {
        XCTAssertEqual(
            try mediaUri("http://audio.xmcdn.com/x.mp3"),
            "https://audio.xmcdn.com/x.mp3",
            "media_upgrade_cdn"
        )
        XCTAssertEqual(
            try mediaUri("http://www.ximalaya.com/x.mp3"),
            "https://www.ximalaya.com/x.mp3",
            "media_upgrade_main"
        )
        XCTAssertEqual(
            try mediaUri("https://audio.xmcdn.com/x.mp3"),
            "https://audio.xmcdn.com/x.mp3",
            "media_https_passthrough"
        )
        XCTAssertEqual(
            try mediaUri("http://example.com/x.mp3"),
            "http://example.com/x.mp3",
            "media_untrusted_passthrough"
        )
        XCTAssertEqual(
            try mediaUri("http://audio.xmcdn.com:8080/x.mp3"),
            "http://audio.xmcdn.com:8080/x.mp3",
            "media_nonstandard_port"
        )
        // Kotlin replaceFirst 只替换小写 "http://"；大写 scheme 保持原样。
        XCTAssertEqual(
            try mediaUri("HTTP://audio.xmcdn.com/x.mp3"),
            "HTTP://audio.xmcdn.com/x.mp3",
            "media_uppercase_scheme"
        )
    }

    func testMediaUriRejectsInvalid() {
        for value in ["", "ftp://audio.xmcdn.com/x.mp3", "http://user@xmcdn.com/x"] {
            XCTAssertThrowsError(try mediaUri(value), "media_invalid") { error in
                guard let xmly = error as? XmlyError else {
                    return XCTFail("media_invalid_type")
                }
                XCTAssertEqual(xmly.code, "invalid_media", "media_invalid_code")
            }
        }
    }

    func testCoverUrlPrefersFirstValidKey() {
        let raw: [String: Any] = [
            "coverLarge": "http://image.xmcdn.com/large.jpg",
            "coverSmall": "https://image.xmcdn.com/small.jpg"
        ]
        XCTAssertEqual(
            coverUrl(raw), "https://image.xmcdn.com/large.jpg", "cover_first_key"
        )
    }

    func testCoverUrlHandlesProtocolRelativeAndHttp() {
        XCTAssertEqual(
            coverUrl(["cover_url": "//image.xmcdn.com/a.jpg"]),
            "https://image.xmcdn.com/a.jpg",
            "cover_protocol_relative"
        )
        XCTAssertEqual(
            coverUrl(["cover_url": "http://example.com/a.jpg"]),
            "http://example.com/a.jpg",
            "cover_non_cdn_http_kept"
        )
        // Swift 侧域名比较先小写，比 Kotlin coverUrl 更宽松：
        // 大写 CDN 域名也会升级（见 BUILD.md §11）。
        XCTAssertEqual(
            coverUrl(["cover_url": "http://IMAGE.XMCDN.COM/a.jpg"]),
            "https://IMAGE.XMCDN.COM/a.jpg",
            "cover_uppercase_host"
        )
        XCTAssertNil(coverUrl(["cover_url": "not a url"]), "cover_invalid")
        XCTAssertNil(coverUrl([:]), "cover_missing")
    }

    func testCoverUrlParsesCamelCaseAndFallbackKeysWithoutBreakingPriority() {
        XCTAssertEqual(
            coverUrl([
                "coverLarge": "https://image.xmcdn.com/large.jpg",
                "coverOrigin": "https://image.xmcdn.com/origin.jpg"
            ]),
            "https://image.xmcdn.com/large.jpg",
            "cover_original_priority_kept"
        )
        XCTAssertEqual(
            coverUrl(["coverOrigin": "http://image.xmcdn.com/origin.jpg"]),
            "https://image.xmcdn.com/origin.jpg",
            "cover_origin_upgraded"
        )
        XCTAssertEqual(
            coverUrl(["coverPath": "//image.xmcdn.com/path.jpg"]),
            "https://image.xmcdn.com/path.jpg",
            "cover_path_protocol_relative"
        )
        XCTAssertEqual(
            coverUrl(["coverWebLarge": "https://image.xmcdn.com/weblarge.jpg"]),
            "https://image.xmcdn.com/weblarge.jpg",
            "cover_web_large"
        )
        XCTAssertEqual(
            coverUrl(["pic": "https://image.xmcdn.com/pic.jpg"]),
            "https://image.xmcdn.com/pic.jpg",
            "cover_pic_fallback"
        )
    }

    func testPublicRawKeepsOnlyPublicScalars() {
        let raw: [String: Any] = [
            "title": "标题",
            "duration": 123,
            "isPaid": true,
            "token": "secret-fixture",
            "tracks": [["id": "1"]],
            "userInfo": ["nickname": "主播", "uid": "999"],
            "unknownKey": "drop"
        ]
        let kept = publicRaw(raw)
        XCTAssertEqual(kept["title"] as? String, "标题", "raw_title")
        XCTAssertEqual(kept["duration"] as? Int, 123, "raw_duration")
        XCTAssertEqual(kept["isPaid"] as? Bool, true, "raw_bool")
        XCTAssertNil(kept["token"], "raw_token_dropped")
        XCTAssertNil(kept["tracks"], "raw_array_dropped")
        XCTAssertNil(kept["unknownKey"], "raw_unknown_dropped")
        let user = kept["userInfo"] as? [String: Any]
        XCTAssertEqual(user?["nickname"] as? String, "主播", "raw_nickname")
        XCTAssertNil(user?["uid"], "raw_user_uid_dropped")
    }

    // MARK: - Track / Album

    func testTrackCanonicalIdAndAlbumKey() throws {
        let track = try Track(
            rawId: "xmly:123",
            title: "标题",
            albumId: "xmly:456",
            raw: ["title": "标题", "token": "secret-fixture"]
        )
        XCTAssertEqual(track.id, "xmly:123", "track_id")
        XCTAssertEqual(track.number, "123", "track_number")
        XCTAssertEqual(track.albumKey, "456", "track_album_key")
        // toJson 的 album_id 用规范化后的 albumKey，与 Kotlin 一致。
        XCTAssertEqual(
            track.toJson()["album_id"] as? String, "456", "track_json_album_id"
        )
        XCTAssertEqual(track.toJson()["id"] as? String, "xmly:123", "track_json_id")
        XCTAssertNil(track.raw["token"], "track_raw_token_dropped")
        XCTAssertEqual(track.raw["title"] as? String, "标题", "track_raw_title")
    }

    func testTrackRejectsInvalidAlbumAndNonFiniteDuration() {
        XCTAssertThrowsError(
            try Track(rawId: "123", albumId: "bad"),
            "track_bad_album"
        )
        XCTAssertThrowsError(
            try Track(rawId: "123", duration: .nan),
            "track_bad_duration"
        )
    }

    func testTrackCodableRoundTrip() throws {
        let original = try Track(
            rawId: "123", title: "标题", albumId: "456", duration: 60,
            orderNo: 3, isPaid: true, intro: "简介"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded.id, original.id, "track_codable_id")
        XCTAssertEqual(decoded.toJson()["album_id"] as? String, "456", "track_codable_album")
        XCTAssertEqual(decoded.orderNo, 3, "track_codable_order")
        XCTAssertEqual(decoded.isPaid, true, "track_codable_paid")
    }

    func testAlbumIdIsBareDigits() throws {
        let album = try Album(rawId: "xmly:7", title: "专辑")
        XCTAssertEqual(album.id, "7", "album_id_bare")
    }

    // MARK: - Comment / updates / history

    func testCommentPageHelpers() {
        let comment = Comment(
            id: "1", uid: "2", nickname: "n", avatarUrl: nil,
            content: "c", createdAt: "2023-09", likes: 3, replyCount: 1
        )
        XCTAssertTrue(comment.hasTime, "comment_has_time")
        XCTAssertFalse(
            Comment(id: "1", uid: "2", nickname: "n", content: "c", createdAt: "").hasTime,
            "comment_no_time"
        )
        let page = CommentPage(comments: [comment], page: 1, totalPages: 2, total: 11)
        XCTAssertTrue(page.hasMore, "comment_page_more")
        XCTAssertFalse(
            CommentPage(comments: [], page: 2, totalPages: 2, total: 11).hasMore,
            "comment_page_last"
        )
    }

    func testUpdateItemFieldNamesMatchKotlin() throws {
        let track = try Track(rawId: "123")
        let item = UpdateItem(track: track, publishedAt: 1_700_000_000_000)
        XCTAssertEqual(item.publishedAt, 1_700_000_000_000, "update_published_at")
        let page = UpdatePage(items: [item], hasMore: true, nextTimeline: 999)
        XCTAssertEqual(page.nextTimeline, 999, "update_next_timeline")
    }

    // MARK: - Quota

    func testQuotaFromStateToleratesMissingFields() {
        let full = Quota.fromState([
            "remainingSeconds": 3600,
            "newDevice": true,
            "checkedAt": 1_700_000_000_000
        ])
        XCTAssertEqual(full?.remainingSeconds, 3600, "quota_full_remaining")
        XCTAssertEqual(full?.newDevice, true, "quota_full_device")
        XCTAssertEqual(
            full?.checkedAt,
            Date(timeIntervalSince1970: 1_700_000_000),
            "quota_full_date"
        )

        // 缺字段取 Kotlin 默认值：newDevice=false、checkedAt=epoch 0。
        let partial = Quota.fromState(["remainingSeconds": 60])
        XCTAssertEqual(partial?.remainingSeconds, 60, "quota_partial_remaining")
        XCTAssertEqual(partial?.newDevice, false, "quota_partial_device")
        XCTAssertEqual(
            partial?.checkedAt, Date(timeIntervalSince1970: 0), "quota_partial_date"
        )

        XCTAssertNil(Quota.fromState(["remainingSeconds": -1]), "quota_negative")
        XCTAssertNil(Quota.fromState(["remainingSeconds": "abc"]), "quota_wrong_type")
        XCTAssertNil(Quota.fromState(["remainingSeconds": ["nested": 1]]), "quota_object")
        XCTAssertNil(Quota.fromState(nil), "quota_nil")
        XCTAssertNil(Quota.fromState("not-a-dict"), "quota_not_dict")
    }

    func testQuotaInitRejectsNegative() {
        XCTAssertThrowsError(
            try Quota(
                remainingSeconds: -1, newDevice: false,
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            "quota_init_negative"
        )
    }

    func testQuotaMillisecondRoundTripIsExact() throws {
        let quota = try Quota(
            remainingSeconds: 3600, newDevice: false,
            checkedAtMillis: 1_700_000_000_123
        )
        XCTAssertEqual(quota.checkedAtMillis, 1_700_000_000_123, "quota_millis_exact")
        XCTAssertEqual(
            quota.stateJSON["checkedAt"] as? Int64,
            1_700_000_000_123,
            "quota_json_millis"
        )
        let restored = Quota.fromState(quota.stateJSON)
        XCTAssertEqual(
            restored?.checkedAtMillis, 1_700_000_000_123, "quota_millis_roundtrip"
        )
    }

    func testQuotaFromStateAppliesOrgJsonCoercion() {
        // 数值字符串可解析；字符串布尔按 "true" 解析；数值布尔为 false。
        XCTAssertEqual(
            Quota.fromState(["remainingSeconds": "60"])?.remainingSeconds,
            60, "quota_string_int"
        )
        XCTAssertEqual(
            Quota.fromState(["remainingSeconds": 60, "newDevice": "true"])?.newDevice,
            true, "quota_string_bool"
        )
        XCTAssertEqual(
            Quota.fromState(["remainingSeconds": 60, "newDevice": 1])?.newDevice,
            false, "quota_numeric_bool"
        )
        XCTAssertEqual(
            Quota.fromState([
                "remainingSeconds": "60",
                "checkedAt": "1700000000123"
            ])?.checkedAtMillis,
            1_700_000_000_123, "quota_string_millis"
        )
        // Java Number.intValue() 语义：64 位整数向 32 位回绕；
        // 浮点向零截断；数值字符串严格解析（"60.9"、"6e1" 均不接受）。
        XCTAssertEqual(
            Quota.fromState([
                "remainingSeconds": NSNumber(value: Int64(4_294_967_297))
            ])?.remainingSeconds,
            1, "quota_wrap_int32"
        )
        XCTAssertEqual(
            Quota.fromState(["remainingSeconds": 60.9])?.remainingSeconds,
            60, "quota_double_truncate"
        )
        XCTAssertNil(
            Quota.fromState(["remainingSeconds": "60.9"]), "quota_string_float"
        )
        XCTAssertNil(
            Quota.fromState(["remainingSeconds": "6e1"]), "quota_string_exponent"
        )
        // xmlyJsonBool 的通用契约：数值取默认值；"true"／"false" 字符串认值
        //（忽略大小写），其他字符串取默认值。
        XCTAssertTrue(xmlyJsonBool(NSNumber(value: 1), default: true), "json_bool_number_fallback")
        XCTAssertTrue(xmlyJsonBool("yes", default: true), "json_bool_string_fallback_true")
        XCTAssertFalse(xmlyJsonBool("yes", default: false), "json_bool_string_fallback_false")
        XCTAssertTrue(xmlyJsonBool("TRUE", default: false), "json_bool_string_case")
        XCTAssertFalse(xmlyJsonBool("FALSE", default: true), "json_bool_string_false")
    }

    func testQuotaCodableRoundTripWithExtremeMillis() throws {
        let quota = try Quota(
            remainingSeconds: 1, newDevice: false,
            checkedAtMillis: Int64.max - 1
        )
        let data = try JSONEncoder().encode(quota)
        let decoded = try JSONDecoder().decode(Quota.self, from: data)
        XCTAssertEqual(decoded.checkedAtMillis, Int64.max - 1, "quota_codable_extreme")
        XCTAssertEqual(decoded.remainingSeconds, 1, "quota_codable_remaining")
    }

    func testQuotaRejectsOverInt32Max() {
        XCTAssertThrowsError(
            try Quota(
                remainingSeconds: Int(Int32.max) + 1, newDevice: false,
                checkedAt: Date(timeIntervalSince1970: 0)
            ),
            "quota_over_int32"
        )
        XCTAssertNil(
            Quota.fromState(["remainingSeconds": Int(Int32.max) + 1]),
            "quota_fromstate_over_int32"
        )
        XCTAssertNotNil(
            Quota.fromState(["remainingSeconds": Int(Int32.max)]),
            "quota_fromstate_int32_max"
        )
    }

    func testModelDefaultsMatchKotlin() throws {
        let comment = Comment()
        XCTAssertEqual(comment.id, "", "default_comment_id")
        XCTAssertEqual(comment.likes, 0, "default_comment_likes")
        XCTAssertTrue(comment.replies.isEmpty, "default_comment_replies")

        let credentials = try Credentials(
            token: "123456&fixture-token", deviceId: "fixture-device-1"
        )
        let login = LoginResult(credentials: credentials)
        XCTAssertEqual(login.nickname, "", "default_login_nickname")
        XCTAssertNil(login.avatarUrl, "default_login_avatar")
        XCTAssertEqual(login.mobile, "", "default_login_mobile")

        let page = SearchPage(page: 1, pageSize: 20, total: 0, kind: .track)
        XCTAssertTrue(page.tracks.isEmpty, "default_search_tracks")
        XCTAssertTrue(page.albums.isEmpty, "default_search_albums")
    }

    func testSensitiveCarriersAreRedacted() throws {
        let track = try Track(rawId: "123")
        let audio = ResolvedAudio(
            url: "https://audio.xmcdn.com/secret-token-x.mp3",
            headers: ["Authorization": "Bearer secret-fixture"],
            requiresReward: false,
            track: track,
            actualQuality: "m4a_128",
            accountIdentity: "identity-fixture"
        )
        XCTAssertEqual(audio.description, "ResolvedAudio(redacted)", "redact_audio_desc")
        XCTAssertFalse(
            String(reflecting: audio).contains("secret-token-x"), "redact_audio_url"
        )
        XCTAssertFalse(
            String(reflecting: audio).contains("Bearer"), "redact_audio_header"
        )
        XCTAssertFalse(
            String(reflecting: audio).contains("identity-fixture"),
            "redact_audio_identity"
        )

        let credentials = try Credentials(
            token: "123456&fixture-token", deviceId: "fixture-device-1"
        )
        let login = LoginResult(
            credentials: credentials, nickname: "n", mobile: "13812345678"
        )
        XCTAssertEqual(login.description, "LoginResult(redacted)", "redact_login_desc")
        XCTAssertFalse(
            String(reflecting: login).contains("13812345678"), "redact_login_mobile"
        )
        XCTAssertFalse(
            String(reflecting: login).contains("fixture-token"), "redact_login_token"
        )

        let summary = AccountSummary(
            identity: "deadbeef-identity-fixture",
            uid: "123456",
            deviceHint: "…ce-1",
            quota: nil,
            paused: false,
            primary: true,
            active: true,
            nickname: "测试",
            mobile: "138****5678"
        )
        XCTAssertEqual(
            String(describing: summary), "AccountSummary(redacted)", "redact_summary_desc"
        )
        XCTAssertEqual(
            String(reflecting: summary), "AccountSummary(redacted)", "redact_summary_debug"
        )
        let children = Array(Mirror(reflecting: summary).children)
        XCTAssertEqual(children.count, 1, "redact_summary_mirror_count")
        XCTAssertEqual(children.first?.label, "value", "redact_summary_mirror_label")
        XCTAssertEqual(
            children.first?.value as? String, "redacted", "redact_summary_mirror_value"
        )
    }
}
