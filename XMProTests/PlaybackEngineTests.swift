import Foundation
import XCTest
@testable import XMPro

@MainActor
private final class TestPlaybackDriver: PlaybackDriver {
    enum Call: Equatable {
        case play
        case seek(Int64)
    }

    var onEvent: ((PlaybackDriverEvent) -> Void)?
    var items: [PlaybackItem] = []
    var current: PlaybackItem?
    var speed = 1.0
    var volume = 1.0
    var playCallCount = 0
    var seekPositions: [Int64] = []
    var calls: [Call] = []
    var reportsPlaying = true

    var seekCallCount: Int { seekPositions.count }

    func load(_ item: PlaybackItem) throws {
        current = item
        items.append(item)
    }

    func play() {
        playCallCount += 1
        calls.append(.play)
        if reportsPlaying, let current {
            onEvent?(.playing(current.id))
        }
    }

    func pause() {
        if let current { onEvent?(.paused(current.id)) }
    }

    func seek(to positionMs: Int64) {
        seekPositions.append(positionMs)
        calls.append(.seek(positionMs))
    }

    func setSpeed(_ speed: Double) { self.speed = speed }
    func setVolume(_ volume: Double) { self.volume = volume }
    func stop() { current = nil }
}

@MainActor
final class PlaybackEngineTests: XCTestCase {
    private func item(start: Int64 = 0) -> PlaybackItem {
        PlaybackItem(
            url: URL(string: "https://example.invalid/audio.m4a")!,
            durationMs: 100_000, startPositionMs: start
        )
    }

    func testExplicitStateTransitions() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        XCTAssertEqual(engine.snapshot.state, .idle)
        let item = item()
        try engine.load(item)
        XCTAssertEqual(engine.snapshot.state, .loading)
        driver.onEvent?(.prepared(item.id))
        XCTAssertEqual(engine.snapshot.state, .playing)
        engine.pause()
        XCTAssertEqual(engine.snapshot.state, .paused)
        engine.play()
        XCTAssertEqual(engine.snapshot.state, .playing)
        driver.onEvent?(.ended(item.id))
        XCTAssertEqual(engine.snapshot.state, .ended)
        engine.stop()
        XCTAssertEqual(engine.snapshot.state, .idle)
    }

    func testEndedEventIsEmittedOnce() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let item = item()
        var ended: [UUID] = []
        engine.onEvent = {
            if case let .ended(id) = $0 { ended.append(id) }
        }
        try engine.load(item)
        driver.onEvent?(.prepared(item.id))
        driver.onEvent?(.ended(item.id))
        driver.onEvent?(.ended(item.id))
        XCTAssertEqual(ended, [item.id])
    }

    func testHTTPErrorMappingFromUnderlyingNSError() {
        let underlying = NSError(
            domain: "SyntheticHTTP", code: -1,
            userInfo: ["HTTPStatusCode": 403]
        )
        let outer = NSError(
            domain: "SyntheticAV", code: -2,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )
        XCTAssertEqual(PlaybackFailure.map(outer).httpStatus, 403)
        XCTAssertTrue(PlaybackFailure.map(outer).message.contains("HTTP 403"))
        XCTAssertEqual(
            PlaybackFailure.map(outer, httpStatus: 404).httpStatus, 404
        )
    }

    func testFailureStopsPlayingAndUsesSafeDomainCodeFallback() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let item = item()
        try engine.load(item)
        driver.onEvent?(.prepared(item.id))
        let failure = PlaybackFailure.map(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        )
        driver.onEvent?(.failed(item.id, failure))
        XCTAssertEqual(engine.snapshot.state, .failed)
        XCTAssertEqual(engine.snapshot.failure, failure)
        XCTAssertTrue(failure.message.contains(NSURLErrorDomain))
        engine.play()
        XCTAssertEqual(engine.snapshot.state, .failed)
    }

    func testStartPositionIsPassedIntoItemPreparation() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let item = item(start: 12_345)
        try engine.load(item)
        XCTAssertEqual(driver.items.first?.startPositionMs, 12_345)
        XCTAssertEqual(engine.snapshot.positionMs, 12_345)
        XCTAssertEqual(engine.snapshot.state, .loading)
        engine.pause()
        driver.onEvent?(.prepared(item.id))
        XCTAssertEqual(engine.snapshot.state, .paused)
    }

    func testStaleEventsAndAudioPauseRequest() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let first = item()
        let second = item()
        try engine.load(first)
        try engine.load(second)
        driver.onEvent?(.prepared(first.id))
        driver.onEvent?(.ended(first.id))
        XCTAssertEqual(engine.snapshot.itemID, second.id)
        XCTAssertEqual(engine.snapshot.state, .loading)
        driver.onEvent?(.prepared(second.id))
        driver.onEvent?(.pauseRequested)
        XCTAssertEqual(engine.snapshot.state, .paused)
    }

    func testRepeatedPlayWhilePlayingIsIdempotent() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let item = item()
        try engine.load(item)
        driver.onEvent?(.prepared(item.id))
        XCTAssertEqual(engine.snapshot.state, .playing)
        XCTAssertEqual(driver.playCallCount, 1)

        var eventCount = 0
        engine.onEvent = { _ in eventCount += 1 }
        engine.play()
        engine.play()

        XCTAssertEqual(engine.snapshot.state, .playing)
        XCTAssertEqual(driver.playCallCount, 1)
        XCTAssertEqual(driver.seekCallCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testPauseThenPlayDuringPreparationRestoresDriverPlaybackIntent() throws {
        let driver = TestPlaybackDriver()
        // 模拟尚未 ready 的驱动：记录 play，但暂不发送 playing。
        driver.reportsPlaying = false
        let engine = PlaybackEngine(driver: driver)
        let item = item()
        try engine.load(item)
        engine.pause()
        XCTAssertEqual(engine.snapshot.state, .paused)
        let playCountBeforeResume = driver.playCallCount

        engine.play()

        XCTAssertEqual(engine.snapshot.state, .loading)
        XCTAssertEqual(driver.playCallCount, playCountBeforeResume + 1)

        driver.reportsPlaying = true
        driver.onEvent?(.prepared(item.id))

        XCTAssertEqual(driver.playCallCount, playCountBeforeResume + 2)
        XCTAssertEqual(engine.snapshot.state, .playing)
    }

    func testPlayAfterEndedSeeksToZeroBeforePlayingAndCanEndAgain() throws {
        let driver = TestPlaybackDriver()
        let engine = PlaybackEngine(driver: driver)
        let item = item()
        var ended: [UUID] = []
        engine.onEvent = {
            if case let .ended(id) = $0 { ended.append(id) }
        }
        try engine.load(item)
        driver.onEvent?(.prepared(item.id))
        driver.onEvent?(.time(
            item.id, positionMs: 100_000, durationMs: 100_000
        ))
        driver.onEvent?(.ended(item.id))
        XCTAssertEqual(engine.snapshot.state, .ended)
        XCTAssertEqual(ended, [item.id])

        engine.play()

        XCTAssertEqual(driver.seekCallCount, 1)
        XCTAssertEqual(driver.seekPositions, [0])
        XCTAssertEqual(driver.playCallCount, 2)
        XCTAssertEqual(driver.calls, [.play, .seek(0), .play])
        XCTAssertEqual(engine.snapshot.positionMs, 0)
        XCTAssertEqual(engine.snapshot.state, .playing)

        driver.onEvent?(.ended(item.id))
        driver.onEvent?(.ended(item.id))
        XCTAssertEqual(engine.snapshot.state, .ended)
        XCTAssertEqual(ended, [item.id, item.id])
    }
}
