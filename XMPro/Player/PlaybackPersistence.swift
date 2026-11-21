import Foundation

struct LocalPlaybackProgress: Codable, Sendable {
    let identity: String?
    let track: Track
    let positionSeconds: Double
    let updatedAt: Int64

    var record: HistoryRecord {
        HistoryRecord(
            track: track, positionSeconds: positionSeconds, updatedAt: updatedAt
        )
    }
}

struct PendingPlaybackSync: Codable, Sendable, Identifiable {
    let id: UUID
    let identity: String
    let track: Track
    let positionSeconds: Double
    let startedAtMs: Int64
    let endedAtMs: Int64
    var isRetry: Bool

    init(
        id: UUID = UUID(), identity: String, track: Track,
        positionSeconds: Double, startedAtMs: Int64, endedAtMs: Int64,
        isRetry: Bool = false
    ) {
        self.id = id
        self.identity = identity
        self.track = track
        self.positionSeconds = positionSeconds
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.isRetry = isRetry
    }
}

struct PlaybackStoredState: Sendable {
    var settings = PlaybackSettings()
    var progress: [LocalPlaybackProgress] = []
    var pendingSync: [PendingPlaybackSync] = []
}

@MainActor
protocol PlaybackStore: AnyObject {
    func load() async throws -> PlaybackStoredState
    func save(_ state: PlaybackStoredState) async throws
}

@MainActor
final class StatePlaybackStore: PlaybackStore {
    private let repository: StateRepository

    init(repository: StateRepository) {
        self.repository = repository
    }

    func load() async throws -> PlaybackStoredState {
        let document = await repository.state()
        let decoder = JSONDecoder()

        func decode<T: Decodable>(_ type: T.Type, value: Any?) throws -> T? {
            guard let value else { return nil }
            let data = try JSONSerialization.data(withJSONObject: value)
            return try decoder.decode(type, from: data)
        }

        return PlaybackStoredState(
            settings: PlaybackSettings(
                json: document.settings["playback"] as? [String: Any] ?? [:]
            ),
            progress: try decode(
                [LocalPlaybackProgress].self,
                value: document.queue["playbackProgress"]
            ) ?? [],
            pendingSync: try decode(
                [PendingPlaybackSync].self,
                value: document.value(forKey: "pendingSync")
            ) ?? []
        )
    }

    func save(_ state: PlaybackStoredState) async throws {
        let progressData = try JSONEncoder().encode(state.progress)
        let pendingData = try JSONEncoder().encode(state.pendingSync)
        let playbackSettings = state.settings

        try await repository.transaction { document in
            var settings = document.settings
            var playback = settings["playback"] as? [String: Any] ?? [:]
            playback.merge(playbackSettings.dictionary) { _, new in new }
            settings["playback"] = playback
            try document.setSettings(settings)

            var queue = document.queue
            queue["playbackProgress"] = try JSONSerialization.jsonObject(
                with: progressData
            )
            try document.setValue(queue, forKey: "queue")
            try document.setValue(
                JSONSerialization.jsonObject(with: pendingData),
                forKey: "pendingSync"
            )
        }
    }
}

/// 保留 AppDependencies 的非 throwing 初始化；存储故障明确呈现，不覆盖旧文件。
@MainActor
final class UnavailablePlaybackStore: PlaybackStore {
    func load() async throws -> PlaybackStoredState {
        throw StateError.directory
    }

    func save(_ state: PlaybackStoredState) async throws {
        throw StateError.directory
    }
}
