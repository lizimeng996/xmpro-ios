import Foundation

struct PlaybackQueue: Sendable {
    struct Snapshot: Equatable, Sendable {
        let index: Int
        let size: Int

        var hasNext: Bool { index >= 0 && index < size - 1 }
        var hasPrevious: Bool { size > 0 && index > 0 && index < size }
    }

    enum Previous: Equatable, Sendable {
        case restart
        case selected(Int)
    }

    private(set) var queueAll: [Track]
    private(set) var queue: [Track]
    private(set) var queueFrom: Int?
    private(set) var queueTo: Int?
    private(set) var index: Int

    init(_ tracks: [Track] = [], index: Int = 0) {
        queueAll = tracks
        queue = tracks
        self.index = tracks.isEmpty ? 0 : min(max(0, index), tracks.count - 1)
    }

    var current: Track? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var snapshot: Snapshot { Snapshot(index: index, size: queue.count) }
    var hasNext: Bool { snapshot.hasNext }
    var hasPrevious: Bool { snapshot.hasPrevious }
    var isRestricted: Bool { queueFrom != nil && queueTo != nil }

    /// true 表示切片生效。调用方在 current.id 改变时启动新集。
    @discardableResult
    mutating func setRange(start: Int?, end: Int?) -> Bool {
        guard !queueAll.isEmpty else { return false }
        let currentID = current?.id

        guard let start, let end else {
            queue = queueAll
            index = queue.firstIndex { $0.id == currentID } ?? 0
            queueFrom = nil
            queueTo = nil
            return true
        }
        guard start <= end else { return false }

        let window = queueAll.enumerated().compactMap { offset, track in
            let ordinal = track.orderNo ?? offset + 1
            return ordinal >= start && ordinal <= end ? track : nil
        }
        guard !window.isEmpty else { return false }
        queue = window
        index = window.firstIndex { $0.id == currentID } ?? 0
        queueFrom = start
        queueTo = end
        return true
    }

    @discardableResult
    mutating func next() -> Track? {
        guard hasNext else { return nil }
        index += 1
        return current
    }

    mutating func previous(positionMs: Int64) -> Previous {
        guard positionMs <= 5_000, hasPrevious else { return .restart }
        index -= 1
        return .selected(index)
    }
}
