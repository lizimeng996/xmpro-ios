import Foundation
import XCTest
@testable import XMPro

final class ExperienceUserTests: XCTestCase {
    private func service(
        _ transport: FakeHTTPTransport,
        authenticated: Bool = false
    ) throws -> XmlyExperienceService {
        XmlyExperienceService(client: XmlyClientService(
            http: transport,
            accountContext: authenticated ? try B1Fixture.context() : nil,
            clock: B1Fixture.clock()
        ))
    }

    func testUserPageParsesAlbumsAndCountersAnonymously() async throws {
        let transport = FakeHTTPTransport { call, _ in
            b1Check(call.path == "/revision/user", "s4-user-path")
            b1Check(!call.authenticated, "s4-user-anonymous")
            return ["data": [
                "pubPageInfo": [
                    "totalCount": 3,
                    "pubInfoList": [
                        ["id": 0],
                        [
                            "id": 7, "title": "合成专辑",
                            "anchorNickName": "合成主播",
                            "coverPath": "//fixture.xmcdn.com/cover.jpg",
                            "subTitle": "合成简介", "trackCount": 12,
                            "isFinished": true, "isPaid": false
                        ]
                    ]
                ],
                "fansPageInfo": ["totalCount": 4],
                "followingPageInfo": ["totalCount": 5]
            ]]
        }
        let page = try await service(transport).userPage(uid: "101")
        XCTAssertEqual(page.nickname, "合成主播")
        XCTAssertEqual(page.intro, "")
        XCTAssertEqual(page.albums.count, 1)
        XCTAssertEqual(page.albums.first?.intro, "合成简介")
        XCTAssertEqual(page.albums.first?.total, 12)
        XCTAssertEqual(page.totalAlbums, 3)
        XCTAssertEqual(page.followers, 4)
        XCTAssertEqual(page.following, 5)
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertNil(transport.calls.first?.query["includeProfile"])
        XCTAssertEqual(transport.calls.last?.query["includeProfile"], "1")
    }

    func testEmptyAlbumsUseProfileFallback() async throws {
        let transport = FakeHTTPTransport { call, _ in
            if call.query["includeProfile"] == "1" {
                return ["data": [
                    "profile": [
                        "nickname": "无专辑主播",
                        "cover": "synthetic.jpg",
                        "description": "个人简介"
                    ]
                ]]
            }
            return ["data": ["pubPageInfo": [
                "totalCount": 0, "pubInfoList": []
            ]]]
        }
        let page = try await service(transport).userPage(uid: "101")
        XCTAssertTrue(page.albums.isEmpty)
        XCTAssertEqual(page.nickname, "无专辑主播")
        XCTAssertEqual(page.intro, "个人简介")
        XCTAssertEqual(page.avatarUrl, "https://imagev2.xmcdn.com/synthetic.jpg")
        XCTAssertEqual(transport.calls.count, 2)
    }

    func testFollowingAndFansParseFirstPage() async throws {
        let transport = FakeHTTPTransport { _, _ in
            ["data": [
                "followingPageInfo": ["followInfoList": [
                    ["uid": 0],
                    [
                        "uid": 201, "anchorNickName": "关注对象",
                        "coverPath": "a.jpg", "followerCount": 8,
                        "albumCount": 2, "description": "简介"
                    ]
                ]],
                "fansPageInfo": ["fansInfoList": [
                    ["uid": 202, "nickName": "粉丝"]
                ]]
            ]]
        }
        let subject = try service(transport)
        let following = try await subject.following(uid: "101")
        let fans = try await subject.fans(uid: "101")
        XCTAssertEqual(following.count, 1)
        XCTAssertEqual(following.first?.uid, "201")
        XCTAssertEqual(following.first?.followers, 8)
        XCTAssertEqual(following.first?.albums, 2)
        XCTAssertEqual(fans.first?.nickname, "粉丝")
        XCTAssertTrue(transport.calls.allSatisfy { $0.query["page"] == nil })
    }

    func testSocialCountsReadsAllFiveCounters() async throws {
        let transport = FakeHTTPTransport { _, _ in
            ["data": [
                "followingPageInfo": ["totalCount": 1],
                "fansPageInfo": ["totalCount": 2],
                "subscriptionPageInfo": ["totalCount": 3],
                "pubPageInfo": ["totalCount": 4],
                "trackPageInfo": ["totalCount": 5]
            ]]
        }
        let counts = try await service(transport).socialCounts(uid: "101")
        XCTAssertEqual(counts, SocialCounts(
            following: 1, followers: 2, subscriptions: 3, albums: 4, tracks: 5
        ))
    }

    func testEmptyProfileThrowsProfileUnavailable() async throws {
        let transport = FakeHTTPTransport { _, _ in ["data": [:]] }
        let subject = try service(transport, authenticated: true)
        await b1ExpectError(
            "profile_unavailable", "s4-profile-empty", definitive: true
        ) {
            _ = try await subject.profile()
        }
    }

    func testProfilePayloadSecondAttemptSucceeds() async throws {
        let transport = FakeHTTPTransport { call, _ in
            switch call.path {
            case "/revision/my/getCurrentUserInfo":
                throw XmlyError.failure(code: .network, message: "合成失败")
            case "/mobile-user/user/detail":
                b1Check(call.origin == XmlyOrigin.mobile.rawValue, "s4-profile-origin")
                b1Check(call.query["device"] == "android", "s4-profile-device")
                return ["data": ["nickname": "第二接口", "avatar": "a.jpg"]]
            case "/revision/user":
                return ["data": [:]]
            default:
                throw XmlyError.failure(code: .invalidResponse, message: "合成失败")
            }
        }
        let profile = try await service(transport, authenticated: true).profile()
        XCTAssertEqual(profile.nickname, "第二接口")
        XCTAssertEqual(transport.calls.map(\.path), [
            "/revision/my/getCurrentUserInfo",
            "/mobile-user/user/detail",
            "/revision/user"
        ])
    }

    func testProfileRequiresLoginWithoutNetwork() async throws {
        let transport = FakeHTTPTransport { _, _ in ["data": [:]] }
        let subject = try service(transport)
        await b1ExpectError("login_required", "s4-profile-login", definitive: true) {
            _ = try await subject.profile()
        }
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testProfileBFSUsesTextOrderAndIgnoresCountsFailure() async throws {
        let cases = [
            (
                #"{"data":{"name":"先出现","nickname":"后出现","nested":{"name":"更深层"},"avatar":"//fixture.xmcdn.com/a.jpg","personalSignature":"签名"}}"#,
                "先出现"
            ),
            (
                #"{"data":{"nickname":"后出现","name":"先出现","nested":{"name":"更深层"},"avatar":"//fixture.xmcdn.com/a.jpg","personalSignature":"签名"}}"#,
                "后出现"
            )
        ]
        for (raw, expected) in cases {
            let transport = FakeHTTPTransport(
                rawDataHandler: { call, _ in
                    b1Check(
                        call.path == "/revision/my/getCurrentUserInfo",
                        "s4-profile-ordered-path"
                    )
                    return Data(raw.utf8)
                }
            ) { call, _ in
                b1Check(call.path == "/revision/user", "s4-profile-counts-path")
                throw XmlyError.failure(code: .network, message: "合成失败")
            }
            let profile = try await service(transport, authenticated: true).profile()
            XCTAssertEqual(profile.nickname, expected)
            XCTAssertEqual(profile.intro, "签名")
            XCTAssertEqual(profile.avatarUrl, "https://fixture.xmcdn.com/a.jpg")
            XCTAssertNil(profile.followers)
            XCTAssertEqual(transport.calls.map(\.path), [
                "/revision/my/getCurrentUserInfo",
                "/revision/user"
            ])
        }
    }
}
