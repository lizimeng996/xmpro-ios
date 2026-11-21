import Foundation

/// 只投影既有 AlbumPage；适配器调用已有服务，不增加网络接口。
struct PlaybackAlbumPage: Sendable {
    let albumID: String
    let tracks: [Track]
    let page: Int
    let pageSize: Int
    let total: Int

    var hasNextPage: Bool {
        page > 0 && pageSize > 0 && Int64(page) * Int64(pageSize) < Int64(total)
    }
}

@MainActor
protocol PlaybackClient: AnyObject {
    var identity: String { get }
    func resolve(number: String, quality: String) async throws -> ResolvedAudio
    func locateAlbum(albumID: String, trackID: String) async throws
        -> PlaybackAlbumPage?
    func loadAlbum(albumID: String, page: Int, pageSize: Int) async throws
        -> PlaybackAlbumPage
}

extension XmlyClientService: PlaybackClient {
    func locateAlbum(
        albumID: String, trackID: String
    ) async throws -> PlaybackAlbumPage? {
        guard let result = try await albumPageWith(
            albumId: albumID, trackId: trackID, maxPages: 20
        ) else { return nil }
        return PlaybackAlbumPage(
            albumID: albumID, tracks: result.tracks,
            page: result.page, pageSize: result.pageSize, total: result.total
        )
    }

    func loadAlbum(
        albumID: String, page: Int, pageSize: Int
    ) async throws -> PlaybackAlbumPage {
        let result = try await album(
            albumId: albumID, page: page, pageSize: pageSize, ascending: true
        )
        return PlaybackAlbumPage(
            albumID: albumID, tracks: result.tracks,
            page: result.page, pageSize: result.pageSize, total: result.total
        )
    }
}

@MainActor
protocol PlaybackHistory: AnyObject {
    func progress(albumId: String, trackId: String) async throws -> HistoryRecord?
    func sync(
        track: Track, positionSeconds: Double,
        startedAtMs: Int64, endedAtMs: Int64
    ) async throws
}

extension XmlyHistoryService: PlaybackHistory {}

@MainActor
protocol PlaybackClock: AnyObject {
    func now() -> Int64
    func sleep(milliseconds: Int64) async throws
}

@MainActor
final class SystemPlaybackClock: PlaybackClock {
    private let clock: ServerClock

    init(serverClock: ServerClock = .shared) {
        clock = serverClock
    }

    func now() -> Int64 { clock.now() }

    func sleep(milliseconds: Int64) async throws {
        let bounded = min(max(0, milliseconds), 86_400_000)
        try await Task.sleep(nanoseconds: UInt64(bounded) * 1_000_000)
    }
}

func playbackMessage(_ error: Error) -> String {
    if let failure = error as? PlaybackFailure { return failure.message }
    if case let XmlyError.failure(code, message, _, _) = error {
        switch code {
        case .previewOnly:
            return "该声音仅提供试听，无法播放完整内容"
        case .insufficientQuota:
            return "播放额度不足"
        case .authRequired, .loginRequired, .loginExpired:
            return "登录信息已失效，请重新登录"
        default:
            return message.isEmpty ? "播放失败：\(code.rawValue)" : message
        }
    }
    return PlaybackFailure.map(error as NSError).message
}

func isPlaybackAuthenticationError(_ error: Error) -> Bool {
    guard case let XmlyError.failure(code, _, _, _) = error else { return false }
    return code == .authRequired || code == .loginRequired || code == .loginExpired
}
