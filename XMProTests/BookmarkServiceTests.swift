import Foundation
import os
import XCTest
@testable import XMPro

// S4 测试共用合成存储；不调用系统 Keychain，不记录凭据文本。
struct S4Keychain: KeychainStore {
    private struct Storage {
        var values: [String: Data] = [:]
        var saves = 0
        var failAtSave: Int?
        var loadCheck: (@Sendable () -> Bool)?
        var observedStop: Bool?
    }

    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    func save(account: String, service: String, data: Data) throws {
        try storage.withLock { state in
            state.saves += 1
            if state.failAtSave == state.saves {
                throw XmlyError.failure(
                    code: .invalidCredentials, message: "合成存储错误"
                )
            }
            state.values[service + "|" + account] = data
        }
    }

    func load(account: String, service: String) throws -> Data? {
        storage.withLock { state in
            if let check = state.loadCheck {
                state.observedStop = check()
            }
            return state.values[service + "|" + account]
        }
    }

    func delete(account: String, service: String) throws {
        storage.withLock { state in
            state.values.removeValue(forKey: service + "|" + account)
        }
    }

    func allAccounts(service: String) throws -> [String] {
        storage.withLock { state in
            let prefix = service + "|"
            return state.values.keys
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
                .sorted()
        }
    }

    func failAfterSuccessfulSaves(_ count: Int) {
        storage.withLock {
            $0.failAtSave = $0.saves + count + 1
        }
    }

    func checkStopOnLoad(_ check: @escaping @Sendable () -> Bool) {
        storage.withLock {
            $0.loadCheck = check
            $0.observedStop = nil
        }
    }

    var observedStop: Bool? {
        storage.withLock { $0.observedStop }
    }
}

@MainActor
final class S4Harness {
    let directory: URL
    let repository: StateRepository
    let keys: S4Keychain
    let vault: CredentialsVault
    let accounts: AccountStore

    init(test: XCTestCase) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmpro-s4-\(UUID().uuidString)", isDirectory: true)
        repository = try StateRepository.open(directory: directory)
        keys = S4Keychain()
        vault = CredentialsVault(store: keys)
        accounts = AccountStore(
            repository: repository,
            vault: vault,
            installDevice: InstallDevice()
        )
        let repository = repository
        let directory = directory
        test.addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func addAccount(_ uid: String = "101") async throws -> Credentials {
        let credentials = try Credentials(
            token: uid + "&synthetic_s4_only",
            deviceId: "synthetic-s4-device-" + uid
        )
        _ = try await accounts.importCredentials(credentials)
        return credentials
    }

    func coordinator(session: PlaybackSession? = nil) -> AccountCoordinator {
        AccountCoordinator(
            accountStore: accounts,
            repository: repository,
            vault: vault,
            playbackSession: session
        )
    }
}

@MainActor
final class S4PlayerEngine: PlayerEngine {
    var snapshot = PlaybackEngineSnapshot()
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var onStop: (() -> Void)?
    var loaded: [PlaybackItem] = []

    func load(_ item: PlaybackItem) throws {
        loaded.append(item)
        snapshot = PlaybackEngineSnapshot(
            itemID: item.id,
            state: .playing,
            positionMs: item.startPositionMs,
            durationMs: item.durationMs
        )
        emit()
    }

    func play() {
        snapshot.state = .playing
        emit()
    }

    func pause() {
        snapshot.state = .paused
        emit()
    }

    func seek(to positionMs: Int64) {
        snapshot.positionMs = positionMs
        emit()
    }

    func setSpeed(_ speed: Double) {}
    func setVolume(_ volume: Double) {}

    func stop() {
        onStop?()
        snapshot = PlaybackEngineSnapshot()
        emit()
    }

    private func emit() {
        onEvent?(.snapshot(snapshot))
    }
}

@MainActor
final class S4MemoryPlaybackStore: PlaybackStore {
    var value = PlaybackStoredState()

    func load() async throws -> PlaybackStoredState { value }

    func save(_ state: PlaybackStoredState) async throws {
        value = state
    }
}

@MainActor
final class S4PlaybackClient: PlaybackClient {
    let identity: String
    let track: Track
    var requestedQualities: [String] = []

    init(identity: String = "synthetic-account", track: Track) {
        self.identity = identity
        self.track = track
    }

    func resolve(number: String, quality: String) async throws -> ResolvedAudio {
        requestedQualities.append(quality)
        return ResolvedAudio(
            url: "https://fixture.xmcdn.com/s4.m4a",
            requiresReward: false,
            track: track,
            actualQuality: quality == "auto" ? "m4a_128" : quality,
            accountIdentity: identity
        )
    }

    func locateAlbum(
        albumID: String, trackID: String
    ) async throws -> PlaybackAlbumPage? {
        nil
    }

    func loadAlbum(
        albumID: String, page: Int, pageSize: Int
    ) async throws -> PlaybackAlbumPage {
        PlaybackAlbumPage(
            albumID: albumID, tracks: [], page: page,
            pageSize: pageSize, total: 0
        )
    }
}

@MainActor
final class S4PlaybackHistory: PlaybackHistory {
    func progress(
        albumId: String, trackId: String
    ) async throws -> HistoryRecord? {
        nil
    }

    func sync(
        track: Track,
        positionSeconds: Double,
        startedAtMs: Int64,
        endedAtMs: Int64
    ) async throws {}
}

@MainActor
func s4Session(
    engine: S4PlayerEngine,
    store: any PlaybackStore,
    client: S4PlaybackClient
) -> PlaybackSession {
    PlaybackSession(
        engine: engine,
        store: store,
        clock: SystemPlaybackClock(serverClock: B1Fixture.clock()),
        automaticTicker: false,
        systemControlsEnabled: false,
        clientFactory: { client },
        historyFactory: { _ in S4PlaybackHistory() }
    )
}

@MainActor
final class BookmarkServiceTests: XCTestCase {
    func testAdd() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let service = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts, now: { 100 }
        )
        let track = try Track(rawId: "1", title: "合成声音")
        let result = try await service.add(track: track, positionMs: 12_000)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.track.id, track.id)
        XCTAssertEqual(result.first?.positionMs, 12_000)
        XCTAssertEqual(result.first?.createdAt, 100)
    }

    func testRemove() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let service = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts
        )
        let track = try Track(rawId: "1")
        try await service.add(track: track, positionMs: 1)
        let result = try await service.remove(trackId: track.id)
        XCTAssertTrue(result.isEmpty)
    }

    func testListSortsByCreatedAtDescending() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let first = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts, now: { 100 }
        )
        let second = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts, now: { 200 }
        )
        try await first.add(track: Track(rawId: "1"), positionMs: 0)
        try await second.add(track: Track(rawId: "2"), positionMs: 0)
        let result = await first.list()
        XCTAssertEqual(result.map(\.track.number), ["2", "1"])
    }

    func testSameTrackReplacesOldBookmark() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let first = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts, now: { 100 }
        )
        let second = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts, now: { 200 }
        )
        let track = try Track(rawId: "1")
        try await first.add(track: track, positionMs: 1)
        let result = try await second.add(track: track, positionMs: 9)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.positionMs, 9)
        XCTAssertEqual(result.first?.createdAt, 200)
    }

    func testNegativePositionClamped() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let service = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts
        )
        let result = try await service.add(
            track: Track(rawId: "1"), positionMs: -1
        )
        XCTAssertEqual(result.first?.positionMs, 0)
    }

    func testNoActiveAccountIsNoOp() async throws {
        let h = try S4Harness(test: self)
        let service = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts
        )
        let before = try await h.repository.state().encoded()
        let added = try await service.add(track: Track(rawId: "1"), positionMs: 1)
        let removed = try await service.remove(trackId: "xmly:1")
        let listed = await service.list()
        let after = try await h.repository.state().encoded()
        XCTAssertTrue(added.isEmpty && removed.isEmpty && listed.isEmpty)
        XCTAssertEqual(before, after)
    }

    func testSurvivesRepositoryReopen() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let service = XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts
        )
        try await service.add(track: Track(rawId: "1"), positionMs: 42_000)
        await h.repository.close()

        let reopened = try StateRepository.open(directory: h.directory)
        addTeardownBlock { await reopened.close() }
        let accounts = AccountStore(
            repository: reopened, vault: h.vault, installDevice: InstallDevice()
        )
        let restored = await XmlyBookmarkService(
            repository: reopened, accountStore: accounts
        ).list()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.positionMs, 42_000)
    }

    func testMalformedEntriesSkippedAndTolerantFieldsParsed() async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount()
        let identity = credentials.identity
        try await h.repository.transaction { document in
            try document.setValue([
                identity: [
                    "bookmarks": [
                        7,
                        ["position": 1],
                        ["track": ["id": ""]],
                        [
                            "track": [
                                "id": "xmly:3", "title": "合成",
                                "duration": "120", "cover_url": ""
                            ],
                            "position": "123", "createdAt": "456"
                        ]
                    ]
                ]
            ], forKey: "library")
        }
        let result = await XmlyBookmarkService(
            repository: h.repository, accountStore: h.accounts
        ).list()
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.track.number, "3")
        XCTAssertEqual(result.first?.track.duration, 0)
        XCTAssertNil(result.first?.track.coverUrl)
        XCTAssertEqual(result.first?.positionMs, 123)
    }

    @MainActor
    func testAppDependenciesBookmarkSyncAndArtistDisplayName() async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount("101")
        await h.accounts.renameAccount(identity: credentials.identity, nickname: "测试昵称")

        let deps = AppDependencies(
            stateRepository: h.repository,
            credentialsVault: h.vault,
            automaticallyRefreshAccounts: false
        )
        await deps.refreshAccountServices()

        let ownTrack = try Track(
            rawId: "xmly:1001",
            title: "声音",
            artist: "听友101",
            album: "专辑",
            albumId: "88"
        )
        XCTAssertEqual(deps.displayNameForArtist(ownTrack.artist, track: ownTrack), "测试昵称")

        let otherTrack = try Track(
            rawId: "xmly:1002",
            title: "声音2",
            artist: "其他主播",
            album: "专辑",
            albumId: "88"
        )
        XCTAssertEqual(deps.displayNameForArtist(otherTrack.artist, track: otherTrack), "其他主播")

        let service = try XCTUnwrap(deps.bookmarkService)
        let added = try await service.add(track: ownTrack, positionMs: 12_000)
        deps.recordBookmarks(added)
        XCTAssertTrue(deps.isTrackBookmarked(ownTrack.id))
        XCTAssertTrue(deps.isTrackBookmarked("1001"))

        let removed = try await service.remove(trackId: ownTrack.id)
        deps.recordBookmarks(removed)
        XCTAssertFalse(deps.isTrackBookmarked(ownTrack.id))
    }
}
