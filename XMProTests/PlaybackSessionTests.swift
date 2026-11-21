import Foundation
import XCTest
@testable import XMPro

@MainActor
private final class FakePlaybackClock: PlaybackClock {
    var milliseconds: Int64 = 1_000_000
    var reads = 0

    func now() -> Int64 {
        reads += 1
        return milliseconds
    }

    func sleep(milliseconds: Int64) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}

@MainActor
private final class FakePlaybackStore: PlaybackStore {
    var value = PlaybackStoredState()
    var saves = 0
    var failSave = false

    func load() async throws -> PlaybackStoredState { value }

    func save(_ state: PlaybackStoredState) async throws {
        if failSave { throw StateError.writeFailed }
        saves += 1
        value = state
    }
}

@MainActor
private final class FakePlayerEngine: PlayerEngine {
    var snapshot = PlaybackEngineSnapshot()
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var loaded: [PlaybackItem] = []
    var speed = 1.0
    var volume = 1.0

    func load(_ item: PlaybackItem) throws {
        loaded.append(item)
        snapshot = PlaybackEngineSnapshot(
            itemID: item.id, state: .playing,
            positionMs: item.startPositionMs, durationMs: item.durationMs
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

    func setSpeed(_ speed: Double) { self.speed = speed }
    func setVolume(_ volume: Double) { self.volume = volume }

    func stop() {
        snapshot = PlaybackEngineSnapshot()
        emit()
    }

    func advance(to positionMs: Int64) {
        snapshot.positionMs = positionMs
        emit()
    }

    func end() {
        guard let id = snapshot.itemID else { return }
        snapshot.state = .ended
        emit()
        onEvent?(.ended(id))
    }

    private func emit() { onEvent?(.snapshot(snapshot)) }
}

@MainActor
private final class FakePlaybackClient: PlaybackClient {
    let identity: String
    var tracks: [String: Track]
    var locatedPage: PlaybackAlbumPage?
    var pages: [Int: PlaybackAlbumPage] = [:]
    var resolves: [String] = []
    var resolveHandler: ((String, String) async throws -> ResolvedAudio)?
    var loadAlbumHandler: ((String, Int, Int) async throws -> PlaybackAlbumPage)?

    init(identity: String = "account-a", tracks: [Track]) {
        self.identity = identity
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.number, $0) })
    }

    func resolved(_ number: String) throws -> ResolvedAudio {
        guard let track = tracks[number] else {
            throw XmlyError.failure(code: .missingTrack, message: "声音不存在")
        }
        return ResolvedAudio(
            url: "https://example.invalid/\(number).m4a",
            requiresReward: false, track: track,
            actualQuality: "m4a_128", accountIdentity: identity
        )
    }

    func resolve(number: String, quality: String) async throws -> ResolvedAudio {
        resolves.append(number)
        if let resolveHandler { return try await resolveHandler(number, quality) }
        return try resolved(number)
    }

    func locateAlbum(
        albumID: String, trackID: String
    ) async throws -> PlaybackAlbumPage? {
        locatedPage
    }

    func loadAlbum(
        albumID: String, page: Int, pageSize: Int
    ) async throws -> PlaybackAlbumPage {
        if let loadAlbumHandler {
            return try await loadAlbumHandler(albumID, page, pageSize)
        }
        guard let result = pages[page] else {
            throw XmlyError.failure(code: .network, message: "合成网络错误")
        }
        return result
    }
}

@MainActor
private final class FakePlaybackHistory: PlaybackHistory {
    struct Call {
        let track: Track
        let position: Double
        let started: Int64
        let ended: Int64
    }

    var remote: HistoryRecord?
    var calls: [Call] = []
    var fail = false
    var active = 0
    var maximumActive = 0
    var handler: ((Call) async throws -> Void)?

    func progress(
        albumId: String, trackId: String
    ) async throws -> HistoryRecord? {
        remote
    }

    func sync(
        track: Track, positionSeconds: Double,
        startedAtMs: Int64, endedAtMs: Int64
    ) async throws {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let call = Call(
            track: track, position: positionSeconds,
            started: startedAtMs, ended: endedAtMs
        )
        calls.append(call)
        if fail {
            throw XmlyError.failure(code: .network, message: "合成网络错误")
        }
        try await handler?(call)
    }
}

@MainActor
private final class ResolveGate {
    var entered = false
    var continuation: CheckedContinuation<ResolvedAudio, Error>?

    func wait() async throws -> ResolvedAudio {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered = true
        }
    }

    func finish(_ result: ResolvedAudio) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class SyncGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered = true
        }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class PlaybackSessionTests: XCTestCase {
    private func track(
        _ number: Int, duration: Double = 100, order: Int? = nil
    ) throws -> Track {
        try Track(
            rawId: String(number), title: "合成声音 \(number)",
            artist: "合成作者", album: "合成专辑", albumId: "900",
            duration: duration, orderNo: order
        )
    }

    private func make(
        engine: FakePlayerEngine,
        store: FakePlaybackStore,
        clock: FakePlaybackClock,
        client: FakePlaybackClient,
        history: FakePlaybackHistory
    ) -> PlaybackSession {
        PlaybackSession(
            engine: engine, store: store, clock: clock,
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: { client },
            historyFactory: { _ in history }
        )
    }

    private func settle(
        _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("异步条件未满足", file: file, line: line)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "state-tests-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeRepository() throws -> (URL, StateRepository) {
        let directory = try makeDirectory()
        let repository = try StateRepository.open(directory: directory)
        addTeardownBlock { await repository.close() }
        return (directory, repository)
    }

    func testOldResolveCannotReplaceNewSelection() async throws {
        let first = try track(1)
        let second = try track(2)
        let client = FakePlaybackClient(tracks: [first, second])
        let gate = ResolveGate()
        client.resolveHandler = { number, _ in
            if number == "1" { return try await gate.wait() }
            return try client.resolved(number)
        }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        let old = Task { await session.play(track: first) }
        await settle { gate.entered }
        await session.play(track: second)
        gate.finish(try client.resolved("1"))
        await old.value
        XCTAssertEqual(session.track?.id, second.id)
        XCTAssertEqual(engine.loaded.count, 1)
        await session.flush()
    }

    func testManualIntroAndExplicitZeroResume() async throws {
        let track = try track(1)
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(),
            client: FakePlaybackClient(tracks: [track]),
            history: FakePlaybackHistory()
        )
        await session.prepare()
        session.setSkipTrim(enabled: true, intro: 100, outro: 0, mode: "manual")
        await session.play(track: track)
        XCTAssertEqual(engine.loaded.last?.startPositionMs, 10_000)
        await session.play(track: track, resumePositionMs: 0)
        XCTAssertEqual(engine.loaded.last?.startPositionMs, 0)
        await session.play(track: track, resumePositionMs: 25_000)
        XCTAssertEqual(engine.loaded.last?.startPositionMs, 25_000)
        XCTAssertEqual(
            session.introSeekMs(trackSeconds: 1, currentDurationMs: 40_000), 4_000
        )
        session.setSkipTrim(mode: "smart")
        XCTAssertEqual(session.introSeekMs(trackSeconds: 100), 0)
        await session.flush()
    }

    func testShortAudioDoesNotTriggerUnsafeOutro() async throws {
        let track = try track(1, duration: 2)
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(),
            client: FakePlaybackClient(tracks: [track]),
            history: FakePlaybackHistory()
        )
        await session.prepare()
        session.setSkipTrim(enabled: true, intro: 0, outro: 400, mode: "manual")
        await session.play(track: track)
        engine.advance(to: 1_500)
        session.tick()
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 1)
        await session.flush()
    }

    func testSleepTimerCancellationAndExpiry() async throws {
        let track = try track(1)
        let engine = FakePlayerEngine()
        let clock = FakePlaybackClock()
        let session = make(
            engine: engine, store: FakePlaybackStore(), clock: clock,
            client: FakePlaybackClient(tracks: [track]),
            history: FakePlaybackHistory()
        )
        await session.play(track: track)
        session.setSleepTimer(minutes: 1)
        session.setSleepTimer(minutes: nil)
        clock.milliseconds += 61_000
        session.tick()
        XCTAssertEqual(session.state, .playing)
        session.setSleepTimer(minutes: 1)
        clock.milliseconds += 60_000
        session.tick()
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.sleepAtMillis)
        XCTAssertEqual(session.message, "定时关闭已触发")
        await session.flush()
    }

    func testPauseSyncRemainsPinnedToStartingIdentity() async throws {
        let track = try track(1)
        let first = FakePlaybackClient(identity: "account-a", tracks: [track])
        let second = FakePlaybackClient(identity: "account-b", tracks: [track])
        var active: FakePlaybackClient = first
        var identities: [String] = []
        let history = FakePlaybackHistory()
        let engine = FakePlayerEngine()
        let clock = FakePlaybackClock()
        let session = PlaybackSession(
            engine: engine, store: FakePlaybackStore(), clock: clock,
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: { active },
            historyFactory: {
                identities.append($0)
                return history
            }
        )
        await session.play(track: track)
        await session.flush()
        active = second
        clock.milliseconds += 10_000
        engine.advance(to: 12_000)
        session.pause()
        await session.flush()
        XCTAssertEqual(session.sessionIdentity, "account-a")
        XCTAssertEqual(Set(identities), ["account-a"])
        XCTAssertEqual(history.calls.last?.position, 12)
    }

    func testOutroAdvancesOnceDespiteEndedEvent() async throws {
        let tracks = try [track(1), track(2), track(3)]
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(),
            client: FakePlaybackClient(tracks: tracks),
            history: FakePlaybackHistory()
        )
        await session.prepare()
        session.setSkipTrim(enabled: true, intro: 0, outro: 100, mode: "manual")
        await session.playQueue(tracks, index: 0)
        engine.advance(to: 90_000)
        session.tick()
        engine.end()
        await settle { session.track?.id == tracks[1].id && session.isPlaying }
        XCTAssertEqual(engine.loaded.count, 2)
        XCTAssertEqual(session.queue.index, 1)
        await session.flush()
    }

    func testOldTrackEndDoesNotOverridePendingUserSelection() async throws {
        let tracks = try [track(1), track(2), track(3)]
        let client = FakePlaybackClient(tracks: tracks)
        let gate = ResolveGate()
        client.resolveHandler = { number, _ in
            if number == "3" { return try await gate.wait() }
            return try client.resolved(number)
        }
        let unexpectedAdvance = expectation(
            description: "用户选择解析期间，旧集结束不得启动自动选集"
        )
        unexpectedAdvance.isInverted = true
        var observeClientRequests = false
        let engine = FakePlayerEngine()
        let history = FakePlaybackHistory()
        let session = PlaybackSession(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(),
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: {
                if observeClientRequests { unexpectedAdvance.fulfill() }
                return client
            },
            historyFactory: { _ in history }
        )
        await session.playQueue([tracks[0], tracks[1]], index: 0)
        await settle { client.resolves.contains("2") }
        await session.flush()
        let itemID = engine.snapshot.itemID

        let operation = Task { await session.play(track: tracks[2]) }
        await settle { gate.entered }
        XCTAssertEqual(session.track?.id, tracks[0].id)
        XCTAssertEqual(session.state, .playing)

        observeClientRequests = true
        engine.advance(to: 100_000)
        engine.end()
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(
            session.localRecord(
                identity: client.identity, trackId: tracks[0].id
            )?.positionSeconds,
            100
        )

        await fulfillment(of: [unexpectedAdvance], timeout: 0.2)
        XCTAssertEqual(session.track?.id, tracks[0].id)
        XCTAssertEqual(session.queue.current?.id, tracks[0].id)
        XCTAssertEqual(engine.loaded.count, 1)
        XCTAssertNil(session.message)

        observeClientRequests = false
        gate.finish(try client.resolved("3"))
        await operation.value
        XCTAssertEqual(session.track?.id, tracks[2].id)
        XCTAssertEqual(session.queue.current?.id, tracks[2].id)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 2)

        // 新选择提交后，其自身的结束事件仍须正常结算。
        engine.end()
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.message, "已是最后一集")
        XCTAssertEqual(engine.loaded.count, 2)
        await session.flush()
    }

    func testPauseImmediatelyAfterEndCancelsQueuedAutoAdvance() async throws {
        let tracks = try [track(1), track(2)]
        let client = FakePlaybackClient(tracks: tracks)
        let unexpectedAdvance = expectation(
            description: "结束后立即暂停，不得启动已排队的自动选集"
        )
        unexpectedAdvance.isInverted = true
        var observeClientRequests = false
        let engine = FakePlayerEngine()
        let history = FakePlaybackHistory()
        let session = PlaybackSession(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(),
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: {
                if observeClientRequests { unexpectedAdvance.fulfill() }
                return client
            },
            historyFactory: { _ in history }
        )
        await session.playQueue(tracks, index: 0)
        await settle { client.resolves.contains("2") }
        await session.flush()
        let itemID = engine.snapshot.itemID

        observeClientRequests = true
        // 同一 MainActor 执行段内顺序调用，自动续集 Task 尚未开始。
        engine.end()
        session.pause()

        await fulfillment(of: [unexpectedAdvance], timeout: 0.2)
        await session.flush()
        XCTAssertEqual(session.track?.id, tracks[0].id)
        XCTAssertEqual(session.queue.current?.id, tracks[0].id)
        XCTAssertEqual(session.queue.index, 0)
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(engine.snapshot.state, .paused)
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(engine.loaded.count, 1)
        XCTAssertTrue(session.canRequestNext)
    }

    func testPendingSyncIsPersistedAndRetriedInForeground() async throws {
        let track = try track(1)
        let engine = FakePlayerEngine()
        let store = FakePlaybackStore()
        let history = FakePlaybackHistory()
        history.fail = true
        let session = make(
            engine: engine, store: store, clock: FakePlaybackClock(),
            client: FakePlaybackClient(tracks: [track]), history: history
        )
        await session.play(track: track)
        session.pause()
        await session.flush()
        XCTAssertEqual(store.value.pendingSync.count, 1)
        XCTAssertEqual(session.pendingSyncCount, 1)
        XCTAssertEqual(session.state, .paused)

        history.fail = false
        session.onAppForegrounded()
        await settle { session.pendingSyncCount == 0 }
        await session.flush()
        XCTAssertTrue(store.value.pendingSync.isEmpty)
        XCTAssertEqual(session.state, .paused)
    }

    func testSameTrackSyncIsSerialAndNewerBackwardSeekWins() async throws {
        let track = try track(1)
        let engine = FakePlayerEngine()
        let history = FakePlaybackHistory()
        let clock = FakePlaybackClock()
        let session = make(
            engine: engine, store: FakePlaybackStore(), clock: clock,
            client: FakePlaybackClient(tracks: [track]), history: history
        )
        await session.play(track: track)
        await session.flush()
        history.calls.removeAll()

        let gate = SyncGate()
        var shouldWait = true
        history.handler = { _ in
            if shouldWait {
                shouldWait = false
                await gate.wait()
            }
        }
        clock.milliseconds += 1_000
        engine.advance(to: 10_000)
        session.syncProgress()
        await settle { gate.entered }
        clock.milliseconds += 1_000
        session.seekTo(1_000)
        gate.finish()
        await session.flush()

        XCTAssertEqual(history.maximumActive, 1)
        XCTAssertEqual(history.calls.map(\.position), [10, 1])
        XCTAssertLessThan(history.calls[0].ended, history.calls[1].ended)
    }

    func testCrossPageNextAndSpeedPreservation() async throws {
        let last = try track(100, order: 100)
        let next = try track(101, order: 101)
        let client = FakePlaybackClient(tracks: [last, next])
        client.locatedPage = PlaybackAlbumPage(
            albumID: "900", tracks: [last], page: 1, pageSize: 100, total: 101
        )
        client.pages[2] = PlaybackAlbumPage(
            albumID: "900", tracks: [next], page: 2, pageSize: 100, total: 101
        )
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.prepare()
        session.setSpeed(1.75)
        await session.playInAlbum(track: last)
        XCTAssertTrue(session.canRequestNext)
        await session.next()
        XCTAssertEqual(session.track?.id, next.id)
        XCTAssertEqual(session.queue.current?.id, next.id)
        XCTAssertEqual(engine.speed, 1.75)
        XCTAssertFalse(session.canRequestNext)
        await session.flush()
    }

    func testMissingNextPageLeavesLastTrackPlayingWithMessage() async throws {
        let last = try track(100, order: 100)
        let client = FakePlaybackClient(tracks: [last])
        client.locatedPage = PlaybackAlbumPage(
            albumID: "900", tracks: [last], page: 1, pageSize: 100, total: 101
        )
        let session = make(
            engine: FakePlayerEngine(), store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.playInAlbum(track: last)
        await session.next()
        XCTAssertEqual(session.track?.id, last.id)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(session.message, "已是最后一集")
        await session.flush()
    }

    func testNewerRemoteProgressWinsEvenWithSmallerPosition() async throws {
        let track = try track(1)
        let history = FakePlaybackHistory()
        let clock = FakePlaybackClock()
        history.remote = HistoryRecord(
            track: track, positionSeconds: 2, updatedAt: clock.now() + 60_000
        )
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(), clock: clock,
            client: FakePlaybackClient(tracks: [track]), history: history
        )
        await session.play(track: track)
        engine.advance(to: 80_000)
        session.pause()
        await session.flush()
        XCTAssertTrue(history.calls.isEmpty)
        let progress = try await session.progress(trackId: track.id)
        XCTAssertEqual(progress?.positionSeconds, 2)
    }

    func testStopInvalidatesInFlightResolve() async throws {
        let track = try track(1)
        let client = FakePlaybackClient(tracks: [track])
        let gate = ResolveGate()
        client.resolveHandler = { _, _ in try await gate.wait() }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        let operation = Task { await session.play(track: track) }
        await settle { gate.entered }
        session.stop()
        gate.finish(try client.resolved("1"))
        await operation.value
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.track)
        XCTAssertTrue(engine.loaded.isEmpty)
        await session.flush()
    }

    func testFailedSelectionsKeepCurrentPlayback() async throws {
        let first = try track(1)
        let second = try track(2)
        let client = FakePlaybackClient(tracks: [first, second])
        client.resolveHandler = { number, _ in
            if number == "2" {
                throw PlaybackFailure(message: "合成解析失败")
            }
            return try client.resolved(number)
        }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.playQueue([first, second], index: 0)
        engine.advance(to: 12_000)
        let itemID = engine.snapshot.itemID

        for selection in ["single", "album", "next"] {
            switch selection {
            case "single":
                await session.play(track: second)
            case "album":
                await session.playInAlbum(track: second)
            default:
                await session.next()
            }
            XCTAssertEqual(session.track?.id, first.id, selection)
            XCTAssertEqual(session.queue.current?.id, first.id, selection)
            XCTAssertEqual(session.state, .playing, selection)
            XCTAssertEqual(session.positionMs, 12_000, selection)
            XCTAssertEqual(engine.snapshot.itemID, itemID, selection)
            XCTAssertEqual(engine.snapshot.state, .playing, selection)
            XCTAssertEqual(engine.loaded.count, 1, selection)
            XCTAssertTrue(
                session.message?.contains("合成解析失败") == true, selection
            )
        }

        client.resolveHandler = { _, _ in try client.resolved("1") }
        await session.play(track: second)
        XCTAssertEqual(session.message, "播放解析返回了不同的声音")
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(session.state, .playing)

        client.resolveHandler = { _, _ in
            ResolvedAudio(
                url: "file:///invalid-audio.m4a",
                requiresReward: false, track: second,
                actualQuality: "m4a_128", accountIdentity: client.identity
            )
        }
        await session.play(track: second)
        XCTAssertEqual(session.message, "播放解析返回了无效地址")
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(session.track?.id, first.id)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 1)
        await session.flush()
    }

    func testLastNextDoesNotPauseOrInvalidatePendingSelection() async throws {
        let first = try track(1)
        let second = try track(2)
        let client = FakePlaybackClient(tracks: [first, second])
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.play(track: first)
        let itemID = engine.snapshot.itemID

        await session.next()
        XCTAssertEqual(session.message, "已是最后一集")
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(engine.loaded.count, 1)

        let gate = ResolveGate()
        client.resolveHandler = { number, _ in
            if number == "2" { return try await gate.wait() }
            return try client.resolved(number)
        }
        let operation = Task { await session.play(track: second) }
        await settle { gate.entered }
        await session.next()
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.snapshot.itemID, itemID)

        gate.finish(try client.resolved("2"))
        await operation.value
        XCTAssertEqual(session.track?.id, second.id)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 2)
        await session.flush()
    }

    func testNextClientWaitHonorsPauseAndCurrentQueueRange() async throws {
        for action in ["pause", "last", "replace"] {
            let tracks = try (1...4).map { try track($0, order: $0) }
            let client = FakePlaybackClient(tracks: tracks)
            let history = FakePlaybackHistory()
            let gate = SyncGate()
            var waitForClient = false
            let engine = FakePlayerEngine()
            let session = PlaybackSession(
                engine: engine, store: FakePlaybackStore(),
                clock: FakePlaybackClock(),
                automaticTicker: false, systemControlsEnabled: false,
                clientFactory: {
                    if waitForClient { await gate.wait() }
                    return client
                },
                historyFactory: { _ in history }
            )
            await session.playQueue(tracks, index: 0)
            await session.flush()
            let itemID = engine.snapshot.itemID
            waitForClient = true

            let operation = Task { await session.next() }
            await settle { gate.entered }
            XCTAssertEqual(session.state, .playing, action)
            XCTAssertEqual(engine.snapshot.itemID, itemID, action)

            switch action {
            case "pause":
                session.pause()
            case "last":
                await session.setQueueRange(start: 1, end: 1)
            default:
                await session.setQueueRange(start: 3, end: 4)
            }
            XCTAssertEqual(engine.loaded.count, 1, action)
            gate.finish()
            await operation.value

            if action == "replace" {
                XCTAssertEqual(session.track?.id, tracks[3].id)
                XCTAssertEqual(session.queue.current?.id, tracks[3].id)
                XCTAssertEqual(session.queue.index, 1)
                XCTAssertEqual(engine.loaded.count, 2)
                XCTAssertEqual(session.state, .playing)
            } else {
                XCTAssertEqual(session.track?.id, tracks[0].id, action)
                XCTAssertEqual(engine.snapshot.itemID, itemID, action)
                XCTAssertEqual(engine.loaded.count, 1, action)
                XCTAssertEqual(
                    session.state, action == "pause" ? .paused : .playing,
                    action
                )
                if action == "last" {
                    XCTAssertEqual(session.message, "已是最后一集")
                    XCTAssertFalse(session.canRequestNext)
                }
            }
            await session.flush()
        }
    }

    func testNextPrefetchWaitHonorsPauseRangeAndCompletionTTL() async throws {
        for action in ["pause", "last", "replace", "ttl"] {
            let tracks = try (1...4).map { try track($0, order: $0) }
            let client = FakePlaybackClient(tracks: tracks)
            let gate = ResolveGate()
            var secondResolves = 0
            client.resolveHandler = { number, _ in
                if number == "2" {
                    secondResolves += 1
                    if secondResolves == 1 {
                        return try await gate.wait()
                    }
                }
                return try client.resolved(number)
            }
            let clock = FakePlaybackClock()
            let engine = FakePlayerEngine()
            let session = make(
                engine: engine, store: FakePlaybackStore(), clock: clock,
                client: client, history: FakePlaybackHistory()
            )
            await session.playQueue(tracks, index: 0)
            await settle { gate.entered }
            await session.flush()
            let itemID = engine.snapshot.itemID

            // 关闭 ticker 且清空持久化任务后，next 的 TTL 检查是下一次读钟。
            // 同一 MainActor 执行段会接着进入预取等待，避免依赖固定次数 yield。
            let reads = clock.reads
            let operation = Task { await session.next() }
            await settle { clock.reads > reads }
            XCTAssertEqual(session.state, .playing, action)
            XCTAssertEqual(engine.snapshot.itemID, itemID, action)

            switch action {
            case "pause":
                session.pause()
            case "last":
                await session.setQueueRange(start: 1, end: 1)
            case "replace":
                await session.setQueueRange(start: 3, end: 4)
            default:
                clock.milliseconds += 60_001
            }
            gate.finish(try client.resolved("2"))
            await operation.value

            switch action {
            case "pause":
                XCTAssertEqual(session.state, .paused)
                XCTAssertEqual(engine.snapshot.itemID, itemID)
                XCTAssertEqual(engine.loaded.count, 1)
            case "last":
                XCTAssertEqual(session.state, .playing)
                XCTAssertEqual(engine.snapshot.itemID, itemID)
                XCTAssertEqual(engine.loaded.count, 1)
                XCTAssertEqual(session.message, "已是最后一集")
                XCTAssertFalse(session.canRequestNext)
            case "replace":
                XCTAssertEqual(session.track?.id, tracks[3].id)
                XCTAssertEqual(session.queue.current?.id, tracks[3].id)
                XCTAssertEqual(session.queue.index, 1)
                XCTAssertEqual(engine.loaded.count, 2)
            default:
                XCTAssertEqual(secondResolves, 2)
                XCTAssertEqual(session.track?.id, tracks[1].id)
                XCTAssertEqual(session.state, .playing)
                XCTAssertEqual(engine.loaded.count, 2)
            }
            await session.flush()
        }
    }

    func testNextPageWaitHonorsPauseAndRestrictedRange() async throws {
        for shouldPause in [true, false] {
            let last = try track(100, order: 100)
            let next = try track(101, order: 101)
            let client = FakePlaybackClient(tracks: [last, next])
            client.locatedPage = PlaybackAlbumPage(
                albumID: "900", tracks: [last],
                page: 1, pageSize: 100, total: 101
            )
            let nextPage = PlaybackAlbumPage(
                albumID: "900", tracks: [next],
                page: 2, pageSize: 100, total: 101
            )
            let gate = SyncGate()
            var pageLoads = 0
            client.loadAlbumHandler = { _, _, _ in
                pageLoads += 1
                if pageLoads == 1 {
                    // 首次预取失败，让 next 自身进入分页请求。
                    throw PlaybackFailure(message: "合成预取失败")
                }
                await gate.wait()
                return nextPage
            }
            let engine = FakePlayerEngine()
            let session = make(
                engine: engine, store: FakePlaybackStore(),
                clock: FakePlaybackClock(), client: client,
                history: FakePlaybackHistory()
            )
            await session.playInAlbum(track: last)
            await settle { pageLoads == 1 }
            await session.flush()
            let itemID = engine.snapshot.itemID

            let operation = Task { await session.next() }
            await settle { gate.entered }
            XCTAssertEqual(pageLoads, 2)
            XCTAssertEqual(session.state, .playing)

            if shouldPause {
                session.pause()
            } else {
                await session.setQueueRange(start: 100, end: 100)
            }
            gate.finish()
            await operation.value

            XCTAssertEqual(session.track?.id, last.id)
            XCTAssertEqual(session.queue.current?.id, last.id)
            XCTAssertEqual(engine.snapshot.itemID, itemID)
            XCTAssertEqual(engine.loaded.count, 1)
            XCTAssertEqual(session.state, shouldPause ? .paused : .playing)
            XCTAssertFalse(client.resolves.contains("101"))
            if !shouldPause {
                XCTAssertEqual(session.message, "已是最后一集")
                XCTAssertTrue(session.queue.isRestricted)
                XCTAssertFalse(session.canRequestNext)
            }
            await session.flush()
        }
    }

    func testNextPageWaitContinuesAfterRangeIsRestrictedThenCleared() async throws {
        let last = try track(100, order: 100)
        let next = try track(101, order: 101)
        let client = FakePlaybackClient(tracks: [last, next])
        client.locatedPage = PlaybackAlbumPage(
            albumID: "900", tracks: [last],
            page: 1, pageSize: 100, total: 101
        )
        let nextPage = PlaybackAlbumPage(
            albumID: "900", tracks: [next],
            page: 2, pageSize: 100, total: 101
        )
        let gate = SyncGate()
        var pageLoads = 0
        client.loadAlbumHandler = { _, page, _ in
            XCTAssertEqual(page, 2)
            pageLoads += 1
            if pageLoads == 1 {
                // 首次预取失败，让 next 自身进入分页等待。
                throw PlaybackFailure(message: "合成预取失败")
            }
            if pageLoads == 2 {
                await gate.wait()
            }
            return nextPage
        }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.playInAlbum(track: last)
        await settle { pageLoads == 1 }
        await session.flush()
        let itemID = engine.snapshot.itemID

        let operation = Task { await session.next() }
        await settle { gate.entered }
        XCTAssertEqual(pageLoads, 2)

        await session.setQueueRange(start: 100, end: 100)
        XCTAssertTrue(session.queue.isRestricted)
        XCTAssertFalse(session.canRequestNext)
        await session.setQueueRange(start: nil, end: nil)
        XCTAssertFalse(session.queue.isRestricted)
        XCTAssertFalse(session.queue.hasNext)
        XCTAssertTrue(session.canRequestNext)
        XCTAssertEqual(session.queue.current?.id, last.id)
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 1)

        gate.finish()
        await operation.value

        XCTAssertGreaterThanOrEqual(pageLoads, 3)
        XCTAssertEqual(session.track?.id, next.id)
        XCTAssertEqual(session.queue.current?.id, next.id)
        XCTAssertFalse(session.queue.isRestricted)
        XCTAssertEqual(session.state, .playing)
        XCTAssertEqual(engine.loaded.count, 2)
        XCTAssertFalse(session.canRequestNext)
        XCTAssertNil(session.message)
        await session.flush()
    }

    func testNextResolveRechecksRangeBeforeCommit() async throws {
        let tracks = try (1...4).map { try track($0, order: $0) }
        let client = FakePlaybackClient(tracks: tracks)
        let gate = ResolveGate()
        var secondResolves = 0
        client.resolveHandler = { number, _ in
            if number == "2" {
                secondResolves += 1
                if secondResolves == 1 {
                    throw PlaybackFailure(message: "合成预取失败")
                }
                return try await gate.wait()
            }
            return try client.resolved(number)
        }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.playQueue(tracks, index: 0)
        await settle { secondResolves == 1 }

        let operation = Task { await session.next() }
        await settle { gate.entered }
        await session.setQueueRange(start: 3, end: 4)
        XCTAssertEqual(session.track?.id, tracks[0].id)
        XCTAssertEqual(engine.loaded.count, 1)

        gate.finish(try client.resolved("2"))
        await operation.value
        XCTAssertEqual(session.track?.id, tracks[3].id)
        XCTAssertEqual(session.queue.current?.id, tracks[3].id)
        XCTAssertEqual(session.queue.index, 1)
        XCTAssertEqual(engine.loaded.count, 2)
        await session.flush()
    }

    func testExpiredSelectionCannotClearNewerPendingSelection() async throws {
        let tracks = try [track(1), track(2), track(3)]
        let client = FakePlaybackClient(tracks: tracks)
        let oldGate = ResolveGate()
        let newGate = ResolveGate()
        client.resolveHandler = { number, _ in
            if number == "2" { return try await oldGate.wait() }
            if number == "3" { return try await newGate.wait() }
            return try client.resolved(number)
        }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.play(track: tracks[0])
        let itemID = engine.snapshot.itemID

        let old = Task { await session.play(track: tracks[1]) }
        await settle { oldGate.entered }
        let newest = Task { await session.playInAlbum(track: tracks[2]) }
        await settle { newGate.entered }

        oldGate.finish(try client.resolved("2"))
        await old.value
        session.pause()
        newGate.finish(try client.resolved("3"))
        await newest.value

        XCTAssertEqual(session.track?.id, tracks[0].id)
        XCTAssertEqual(engine.snapshot.itemID, itemID)
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(engine.loaded.count, 1)
        await session.flush()
    }

    func testPauseInvalidatesInitialUncommittedSelection() async throws {
        let track = try track(1)
        let client = FakePlaybackClient(tracks: [track])
        let gate = ResolveGate()
        client.resolveHandler = { _, _ in try await gate.wait() }
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        let operation = Task { await session.play(track: track) }
        await settle { gate.entered }
        session.pause()
        gate.finish(try client.resolved("1"))
        await operation.value

        XCTAssertTrue(engine.loaded.isEmpty)
        XCTAssertNil(session.track)
        XCTAssertFalse(session.isPlaying)
        await session.flush()
    }

    func testRangeExcludingCurrentDoesNotChangePlaybackOrPause() async throws {
        for shouldPause in [false, true] {
            let tracks = try (1...4).map { try track($0, order: $0) }
            let engine = FakePlayerEngine()
            let session = make(
                engine: engine, store: FakePlaybackStore(),
                clock: FakePlaybackClock(),
                client: FakePlaybackClient(tracks: tracks),
                history: FakePlaybackHistory()
            )
            await session.playQueue(tracks, index: 0)
            engine.advance(to: 15_000)
            if shouldPause { session.pause() }
            let itemID = engine.snapshot.itemID
            let expectedState: PlaybackState = shouldPause ? .paused : .playing

            await session.setQueueRange(start: 3, end: 4)
            XCTAssertEqual(session.track?.id, tracks[0].id)
            XCTAssertEqual(session.queue.current?.id, tracks[2].id)
            XCTAssertEqual(session.queue.index, 0)
            XCTAssertEqual(session.queue.queueAll.count, 4)
            XCTAssertEqual(session.state, expectedState)
            XCTAssertEqual(engine.snapshot.state, expectedState)
            XCTAssertEqual(engine.snapshot.itemID, itemID)
            XCTAssertEqual(session.positionMs, 15_000)
            XCTAssertEqual(engine.loaded.count, 1)
            await session.flush()
        }
    }

    func testIntroUsesResolvedDurationAndCurrentItemFallback() async throws {
        let catalogue = try track(1, duration: 100)
        let client = FakePlaybackClient(tracks: [catalogue])
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: FakePlaybackStore(),
            clock: FakePlaybackClock(), client: client,
            history: FakePlaybackHistory()
        )
        await session.prepare()
        session.setSkipTrim(enabled: true, intro: 100, outro: 0, mode: "manual")

        let cases: [(seconds: Double, duration: Int64, intro: Int64)] = [
            (200, 200_000, 20_000),
            (1, 1_000, 100),
            (0.5, 500, 50),
            (0, 100_000, 10_000)
        ]
        for value in cases {
            client.tracks["1"] = try track(1, duration: value.seconds)
            await session.play(track: catalogue)
            XCTAssertEqual(engine.loaded.last?.durationMs, value.duration)
            XCTAssertEqual(engine.loaded.last?.startPositionMs, value.intro)
            XCTAssertEqual(session.durationMs, value.duration)
        }
        await session.flush()
    }

    func testLocalTimestampsIncreaseWithinMillisecondAndAfterClockRollback() async throws {
        let track = try track(1)
        let clock = FakePlaybackClock()
        let store = FakePlaybackStore()
        let history = FakePlaybackHistory()
        history.fail = true
        let client = FakePlaybackClient(tracks: [track])
        let engine = FakePlayerEngine()
        let session = make(
            engine: engine, store: store, clock: clock,
            client: client, history: history
        )
        await session.play(track: track)
        await session.flush()
        var timestamps = [try XCTUnwrap(store.value.progress.first?.updatedAt)]

        for rollback in [false, false, true] {
            if rollback { clock.milliseconds -= 60_000 }
            session.onAppBackgrounded()
            await session.flush()
            let timestamp = try XCTUnwrap(store.value.progress.first?.updatedAt)
            let ended = try XCTUnwrap(store.value.pendingSync.first?.endedAtMs)
            XCTAssertGreaterThan(timestamp, ended)
            timestamps.append(timestamp)
        }

        session.stop()
        await session.flush()
        let stopped = try XCTUnwrap(store.value.progress.first?.updatedAt)
        let ended = try XCTUnwrap(store.value.pendingSync.first?.endedAtMs)
        XCTAssertGreaterThan(stopped, ended)
        timestamps.append(stopped)

        for (earlier, later) in zip(timestamps, timestamps.dropFirst()) {
            XCTAssertGreaterThan(later, earlier)
        }

        let restored = make(
            engine: FakePlayerEngine(), store: store, clock: clock,
            client: client, history: history
        )
        await restored.prepare()
        await restored.play(track: track)
        restored.onAppBackgrounded()
        restored.stop()
        await restored.flush()
        let restoredTimestamp = try XCTUnwrap(store.value.progress.first?.updatedAt)
        XCTAssertGreaterThan(restoredTimestamp, stopped)
        XCTAssertGreaterThan(
            restoredTimestamp,
            try XCTUnwrap(store.value.pendingSync.first?.endedAtMs)
        )
    }

    func testStatePlaybackStoreRoundTripPreservesFieldsAndRetriesRestoredSync() async throws {
        let (directory, repository) = try makeRepository()
        try await repository.transaction { document in
            try document.setSettings([
                "appearance": "dark",
                "playback": ["futureOption": "retained"]
            ])
            try document.setValue(
                ["catalogueCursor": "retained"], forKey: "queue"
            )
            try document.setValue("retained", forKey: "futureState")
        }
        let track = try track(1)
        let client = FakePlaybackClient(tracks: [track])
        let history = FakePlaybackHistory()
        history.fail = true
        let engine = FakePlayerEngine()
        let store = StatePlaybackStore(repository: repository)
        let session = PlaybackSession(
            engine: engine, store: store, clock: FakePlaybackClock(),
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: { client },
            historyFactory: { _ in history }
        )
        await session.prepare()
        session.setSpeed(1.75)
        session.setVolume(0.4)
        session.setSkipTrim(enabled: true, intro: 100, outro: 50, mode: "manual")
        await session.play(track: track, resumePositionMs: 0)
        engine.advance(to: 12_000)
        session.pause()
        await session.flush()

        let saved = try await store.load()
        XCTAssertEqual(saved.settings, session.settings)
        XCTAssertEqual(saved.progress.count, 1)
        XCTAssertEqual(saved.progress.first?.track.id, track.id)
        XCTAssertEqual(saved.progress.first?.positionSeconds, 12)
        XCTAssertEqual(saved.pendingSync.count, 1)
        let pending = try XCTUnwrap(saved.pendingSync.first)
        XCTAssertEqual(pending.identity, client.identity)
        XCTAssertEqual(pending.positionSeconds, 12)

        await repository.close()
        let reopened = try StateRepository.open(directory: directory)
        addTeardownBlock { await reopened.close() }
        let restoredStore = StatePlaybackStore(repository: reopened)
        let restoredState = try await restoredStore.load()
        XCTAssertEqual(restoredState.settings, saved.settings)
        XCTAssertEqual(
            restoredState.progress.first?.updatedAt,
            saved.progress.first?.updatedAt
        )
        XCTAssertEqual(restoredState.progress.first?.positionSeconds, 12)
        XCTAssertEqual(restoredState.pendingSync.first?.id, pending.id)
        XCTAssertEqual(restoredState.pendingSync.first?.endedAtMs, pending.endedAtMs)

        let document = await reopened.state()
        XCTAssertEqual(document.settings["appearance"] as? String, "dark")
        let playback = document.settings["playback"] as? [String: Any]
        XCTAssertEqual(playback?["futureOption"] as? String, "retained")
        XCTAssertEqual(document.queue["catalogueCursor"] as? String, "retained")
        XCTAssertEqual(document.value(forKey: "futureState") as? String, "retained")

        let retryHistory = FakePlaybackHistory()
        let restored = PlaybackSession(
            engine: FakePlayerEngine(), store: restoredStore,
            clock: FakePlaybackClock(),
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: { client },
            historyFactory: { identity in
                XCTAssertEqual(identity, pending.identity)
                return retryHistory
            }
        )
        await restored.prepare()
        await restored.flush()

        XCTAssertEqual(restored.pendingSyncCount, 0)
        XCTAssertEqual(retryHistory.calls.count, 1)
        XCTAssertEqual(retryHistory.calls.first?.track.id, track.id)
        XCTAssertEqual(retryHistory.calls.first?.position, pending.positionSeconds)
        XCTAssertEqual(retryHistory.calls.first?.started, pending.startedAtMs)
        XCTAssertEqual(retryHistory.calls.first?.ended, pending.endedAtMs)
        let synced = try await restoredStore.load()
        XCTAssertTrue(synced.pendingSync.isEmpty)
        XCTAssertEqual(synced.settings, saved.settings)
        XCTAssertEqual(synced.progress.first?.positionSeconds, 12)

        let afterSync = await reopened.state()
        XCTAssertEqual(afterSync.settings["appearance"] as? String, "dark")
        let afterPlayback = afterSync.settings["playback"] as? [String: Any]
        XCTAssertEqual(afterPlayback?["futureOption"] as? String, "retained")
        XCTAssertEqual(afterSync.queue["catalogueCursor"] as? String, "retained")
        XCTAssertEqual(afterSync.value(forKey: "futureState") as? String, "retained")
    }

    func testStatePlaybackStoreSaveFailurePreventsNetworkUntilSaved() async throws {
        let (directory, repository) = try makeRepository()
        let store = StatePlaybackStore(repository: repository)
        let track = try track(1)
        let client = FakePlaybackClient(tracks: [track])
        let history = FakePlaybackHistory()
        var historyFactoryCalls = 0
        let session = PlaybackSession(
            engine: FakePlayerEngine(), store: store,
            clock: FakePlaybackClock(),
            automaticTicker: false, systemControlsEnabled: false,
            clientFactory: { client },
            historyFactory: { _ in
                historyFactoryCalls += 1
                return history
            }
        )
        await session.prepare()

        // 用目录占据原子 rename 的目标，制造真实写入失败；
        // 仓库仍然打开，移除故障后可验证同一 session 的重试。
        let destination = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false
        )
        await session.play(track: track)
        await session.flush()

        XCTAssertEqual(historyFactoryCalls, 0)
        XCTAssertTrue(history.calls.isEmpty)
        XCTAssertEqual(session.pendingSyncCount, 1)
        XCTAssertEqual(
            session.message, "本地播放状态保存失败，进度将在下次保存时重试"
        )
        let failedState = try await store.load()
        XCTAssertTrue(failedState.progress.isEmpty)
        XCTAssertTrue(failedState.pendingSync.isEmpty)

        try FileManager.default.removeItem(at: destination)
        session.onAppBackgrounded()
        await session.flush()

        XCTAssertGreaterThan(historyFactoryCalls, 0)
        XCTAssertFalse(history.calls.isEmpty)
        XCTAssertEqual(session.pendingSyncCount, 0)
        let savedState = try await store.load()
        XCTAssertEqual(savedState.progress.first?.track.id, track.id)
        XCTAssertTrue(savedState.pendingSync.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }
}
