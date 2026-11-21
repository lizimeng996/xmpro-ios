import XCTest
@testable import XMPro

final class PlaybackQueueTests: XCTestCase {
    private func tracks() throws -> [Track] {
        try (1...5).map {
            try Track(rawId: String($0), title: "声音\($0)", orderNo: $0)
        }
    }

    func testRangeRetainsCurrentAndOriginalQueue() throws {
        var queue = PlaybackQueue(try tracks(), index: 2)
        XCTAssertTrue(queue.setRange(start: 2, end: 4))
        XCTAssertEqual(queue.current?.number, "3")
        XCTAssertEqual(queue.index, 1)
        XCTAssertEqual(queue.queueAll.count, 5)
        XCTAssertTrue(queue.setRange(start: 1, end: 5))
        XCTAssertEqual(queue.queue.count, 5)
        XCTAssertEqual(queue.current?.number, "3")
    }

    func testRangeExcludingCurrentSelectsFirst() throws {
        var queue = PlaybackQueue(try tracks(), index: 0)
        queue.setRange(start: 3, end: 4)
        XCTAssertEqual(queue.current?.number, "3")
        XCTAssertEqual(queue.index, 0)
        XCTAssertEqual(queue.queueFrom, 3)
        XCTAssertEqual(queue.queueTo, 4)
    }

    func testEmptySliceIsIgnoredAndEitherNilRestoresAll() throws {
        var queue = PlaybackQueue(try tracks(), index: 2)
        queue.setRange(start: 2, end: 4)
        XCTAssertFalse(queue.setRange(start: 9, end: 10))
        XCTAssertEqual(queue.queue.count, 3)
        queue.setRange(start: nil, end: 2)
        XCTAssertEqual(queue.queue.count, 5)
        XCTAssertNil(queue.queueFrom)
        queue.setRange(start: 2, end: 3)
        queue.setRange(start: 2, end: nil)
        XCTAssertEqual(queue.queue.count, 5)
        XCTAssertEqual(queue.current?.number, "3")
    }

    func testPreviousFiveSecondRule() throws {
        var queue = PlaybackQueue(try tracks(), index: 2)
        XCTAssertEqual(queue.previous(positionMs: 5_001), .restart)
        XCTAssertEqual(queue.index, 2)
        XCTAssertEqual(queue.previous(positionMs: 5_000), .selected(1))
        XCTAssertEqual(queue.current?.number, "2")
    }

    func testQueueBoundaries() throws {
        var queue = PlaybackQueue(try tracks())
        XCTAssertEqual(queue.previous(positionMs: 0), .restart)
        for _ in 0..<4 { XCTAssertNotNil(queue.next()) }
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.index, 4)

        var empty = PlaybackQueue()
        XCTAssertNil(empty.next())
        XCTAssertEqual(empty.previous(positionMs: 0), .restart)
        XCTAssertNil(empty.current)
    }

    func testSnapshotAndFallbackOrdinal() throws {
        let tracks = try (1...3).map { try Track(rawId: String($0)) }
        var queue = PlaybackQueue(tracks, index: 1)
        XCTAssertEqual(queue.snapshot, .init(index: 1, size: 3))
        XCTAssertTrue(queue.snapshot.hasNext)
        XCTAssertTrue(queue.snapshot.hasPrevious)
        queue.setRange(start: 2, end: 2)
        XCTAssertEqual(queue.current?.number, "2")
        XCTAssertFalse(queue.snapshot.hasNext)
        XCTAssertFalse(queue.snapshot.hasPrevious)
    }
}
