import XCTest
@testable import XMPro

final class SocialModelsTests: XCTestCase {
    func testCDNURLNormalizesFourForms() {
        XCTAssertEqual(
            cdnUrl("//example.invalid/avatar.jpg"),
            "https://example.invalid/avatar.jpg"
        )
        XCTAssertEqual(
            cdnUrl("http://example.invalid/avatar.jpg"),
            "https://example.invalid/avatar.jpg"
        )
        XCTAssertEqual(
            cdnUrl("https://example.invalid/avatar.jpg"),
            "https://example.invalid/avatar.jpg"
        )
        XCTAssertEqual(
            cdnUrl("group/avatar.jpg"),
            "https://imagev2.xmcdn.com/group/avatar.jpg"
        )
    }

    func testCDNURLRemovesLeadingSlashFromObjectKey() {
        XCTAssertEqual(
            cdnUrl("/group/avatar.jpg"),
            "https://imagev2.xmcdn.com/group/avatar.jpg"
        )
    }

    func testCDNURLRejectsNilEmptyAndBlank() {
        XCTAssertNil(cdnUrl(nil))
        XCTAssertNil(cdnUrl(""))
        XCTAssertNil(cdnUrl(" \t\r\n "))
    }

    func testCDNURLTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            cdnUrl(" \nhttps://example.invalid/avatar.jpg\t "),
            "https://example.invalid/avatar.jpg"
        )
    }

    func testCDNURLRejectsEmbeddedControlsAndSpaces() {
        for separator in [" ", "\t", "\n", "\r", "\u{0000}", "\u{001F}"] {
            XCTAssertNil(cdnUrl("group\(separator)avatar.jpg"))
        }
    }

    func testCDNURLUsesKotlinUTF16LengthLimit() {
        let boundary = String(repeating: "a", count: 16_384)
        XCTAssertEqual(
            cdnUrl(boundary),
            "https://imagev2.xmcdn.com/" + boundary
        )
        XCTAssertNil(cdnUrl(boundary + "a"))

        let supplementary = String(repeating: "\u{1F600}", count: 8_192)
        XCTAssertNotNil(cdnUrl(supplementary))
        XCTAssertNil(cdnUrl(supplementary + "a"))
    }

    func testUserPageDefaults() {
        let value = UserPage(uid: "101")
        XCTAssertEqual(value.uid, "101")
        XCTAssertEqual(value.nickname, "")
        XCTAssertNil(value.avatarUrl)
        XCTAssertEqual(value.intro, "")
        XCTAssertEqual(value.followers, 0)
        XCTAssertEqual(value.following, 0)
        XCTAssertTrue(value.albums.isEmpty)
        XCTAssertEqual(value.totalAlbums, 0)
    }

    func testSocialUserDefaults() {
        let value = SocialUser(uid: "102")
        XCTAssertEqual(value.uid, "102")
        XCTAssertEqual(value.nickname, "")
        XCTAssertNil(value.avatarUrl)
        XCTAssertEqual(value.followers, 0)
        XCTAssertEqual(value.albums, 0)
        XCTAssertEqual(value.intro, "")
    }

    func testUserProfileDefaultsPreserveUnknownCounts() {
        let value = UserProfile(uid: "103")
        XCTAssertEqual(value.uid, "103")
        XCTAssertEqual(value.nickname, "")
        XCTAssertNil(value.avatarUrl)
        XCTAssertEqual(value.intro, "")
        XCTAssertNil(value.followers)
        XCTAssertNil(value.following)
        XCTAssertNil(value.subscriptions)
    }

    func testSocialCountsDefaultToZero() {
        let value = SocialCounts()
        XCTAssertEqual(value.following, 0)
        XCTAssertEqual(value.followers, 0)
        XCTAssertEqual(value.subscriptions, 0)
        XCTAssertEqual(value.albums, 0)
        XCTAssertEqual(value.tracks, 0)
    }
}
