import Foundation
import XCTest
@testable import XMPro

@MainActor
private final class S4ObservedPlaybackStore: PlaybackStore {
    private let underlying: StatePlaybackStore
    var onSave: ((PlaybackStoredState) -> Void)?

    init(repository: StateRepository) {
        underlying = StatePlaybackStore(repository: repository)
    }

    func load() async throws -> PlaybackStoredState {
        try await underlying.load()
    }

    func save(_ state: PlaybackStoredState) async throws {
        try await underlying.save(state)
        onSave?(state)
    }
}

@MainActor
final class QualityLockTests: XCTestCase {
    func testNormalizeQualityPreservesSupportedValues() {
        for quality in ["auto"] + ProtocolConfig.qualities {
            XCTAssertEqual(PlaybackSettings.normalizeQuality(quality), quality)
            XCTAssertEqual(
                PlaybackSettings.normalizeQuality(quality.uppercased()), quality
            )
        }
        XCTAssertEqual(PlaybackSettings.normalizeQuality("invalid"), "auto")
        XCTAssertEqual(PlaybackSettings.normalizeQuality(""), "auto")
        XCTAssertEqual(PlaybackSettings.normalizeQuality("mp3_64"), "mp3_64")
        XCTAssertEqual(PlaybackSettings.normalizeQuality("m4a_24"), "m4a_24")
    }

    func testSetQualityPersistsAndRestoresAcrossRepositoryReopen() async throws {
        let h = try S4Harness(test: self)
        let track = try Track(rawId: "1", duration: 120)
        let store = S4ObservedPlaybackStore(repository: h.repository)
        let client = S4PlaybackClient(track: track)
        let first = s4Session(
            engine: S4PlayerEngine(), store: store, client: client
        )
        await first.prepare()

        let saved = expectation(description: "quality persisted")
        var fulfilled = false
        store.onSave = { state in
            if state.settings.quality == "m4a_24", !fulfilled {
                fulfilled = true
                saved.fulfill()
            }
        }
        first.setQuality("m4a_24")
        await fulfillment(of: [saved], timeout: 3)
        store.onSave = nil

        let state = await h.repository.state()
        let playback = state.settings["playback"] as? [String: Any]
        XCTAssertEqual(playback?["quality"] as? String, "m4a_24")

        await h.repository.close()
        let reopened = try StateRepository.open(directory: h.directory)
        addTeardownBlock { await reopened.close() }
        let secondClient = S4PlaybackClient(track: track)
        let second = s4Session(
            engine: S4PlayerEngine(),
            store: StatePlaybackStore(repository: reopened),
            client: secondClient
        )
        await second.prepare()
        XCTAssertEqual(second.settings.quality, "m4a_24")
        await second.play(track: track)
        XCTAssertEqual(secondClient.requestedQualities.last, "m4a_24")
        second.stop()
    }

    func testResolveUsesRequestedQualityWhenAvailable() async throws {
        var info = B1Fixture.track()
        info["playUrl32"] = "https://fixture.xmcdn.com/32.mp3"
        info["playUrlList"] = [
            ["type": "m4a_128", "url": "https://fixture.xmcdn.com/128.m4a"],
            ["type": "m4a_64", "url": "https://fixture.xmcdn.com/64.m4a"]
        ]
        let payload = try B1Fixture.authorized(info)
        let transport = FakeHTTPTransport { _, _ in payload }
        let client = XmlyClientService(
            http: transport,
            accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        let result = try await client.resolve(number: "1", quality: "m4a_64")
        XCTAssertEqual(result.actualQuality, "m4a_64")
        XCTAssertEqual(result.url, "https://fixture.xmcdn.com/64.m4a")
    }

    func testResolveFallsBackToAvailableMP332() async throws {
        var info = B1Fixture.track()
        info["playUrl32"] = "https://fixture.xmcdn.com/32.mp3"
        let payload = try B1Fixture.authorized(info)
        let transport = FakeHTTPTransport { _, _ in payload }
        let client = XmlyClientService(
            http: transport,
            accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        let result = try await client.resolve(number: "1", quality: "m4a_128")
        XCTAssertEqual(result.actualQuality, "mp3_32")
        XCTAssertEqual(result.url, "https://fixture.xmcdn.com/32.mp3")
    }

    func testResolveWithoutAddressesThrowsDefinitivePermissionDenied() async throws {
        let payload = try B1Fixture.authorized(B1Fixture.track())
        let transport = FakeHTTPTransport { _, _ in payload }
        let client = XmlyClientService(
            http: transport,
            accountContext: try B1Fixture.context(),
            clock: B1Fixture.clock()
        )
        await b1ExpectError(
            "permission_denied", "s4-quality-no-address", definitive: true
        ) {
            _ = try await client.resolve(number: "1", quality: "m4a_128")
        }
    }
}
