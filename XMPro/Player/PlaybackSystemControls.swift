import AVFoundation
import Foundation
import MediaPlayer
import UIKit

@MainActor
final class PlaybackSystemControls {
    var onBackground: (() -> Void)?
    var onForeground: (() -> Void)?

    private let bridge: PlaybackQueueBridge
    private var targets: [(MPRemoteCommand, Any)] = []
    private var notifications: [NSObjectProtocol] = []
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkGeneration = UUID()
    private var lastInfo: [String: Any] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(bridge: PlaybackQueueBridge) {
        self.bridge = bridge
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand, command: .play)
        add(center.pauseCommand, command: .pause)
        add(center.togglePlayPauseCommand, command: .toggle)
        add(center.nextTrackCommand, command: .next)
        add(center.previousTrackCommand, command: .previous)

        let seek = center.changePlaybackPositionCommand
        let target = seek.addTarget { [weak bridge] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite, event.positionTime >= 0 else {
                return .commandFailed
            }
            let position = playbackMilliseconds(event.positionTime)
            Task { @MainActor [weak bridge] in
                bridge?.request(.seek(position))
            }
            return .success
        }
        targets.append((seek, target))

        let notifications = NotificationCenter.default
        self.notifications.append(notifications.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onBackground?() }
        })
        self.notifications.append(notifications.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onForeground?() }
        })
        updateCommands(active: false, hasNext: false)
    }

    private static let audioSessionQueue = DispatchQueue(
        label: "studio.teikeng.xmpro.audiosession",
        qos: .userInitiated
    )

    func activate() throws {
        // 避免在主线程同步调用 AVAudioSession 引发 Hang Risk 警告。
        // 使用 .longFormAudio 路由策略，确保蓝牙音箱与 AirPlay 稳定独占长音频输出。
        Self.audioSessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
            try? session.setActive(true)
        }
    }

    func clear() throws {
        resetNowPlaying()
        updateCommands(active: false, hasNext: false)
        Self.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        }
    }

    func update(
        track: Track?, state: PlaybackState,
        positionMs: Int64, durationMs: Int64, speed: Double, hasNext: Bool
    ) {
        guard let track else {
            resetNowPlaying()
            updateCommands(active: false, hasNext: false)
            return
        }
        lastInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: Double(durationMs) / 1_000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs) / 1_000,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? speed : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: speed,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]

        if artworkURL != track.coverUrl {
            artworkURL = track.coverUrl
            artwork = nil
            loadArtwork(track.coverUrl)
        }
        publishInfo()
        updateCommands(active: true, hasNext: hasNext)
    }

    func beginBackgroundSubmission() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Playback progress"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundSubmission()
            }
        }
    }

    func endBackgroundSubmission() {
        guard backgroundTask != .invalid else { return }
        let identifier = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func resetNowPlaying() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration = UUID()
        artwork = nil
        artworkURL = nil
        lastInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func add(
        _ remote: MPRemoteCommand, command: PlaybackQueueBridge.Command
    ) {
        let target = remote.addTarget { [weak bridge] _ in
            Task { @MainActor [weak bridge] in
                bridge?.request(command)
            }
            return .success
        }
        targets.append((remote, target))
    }

    private func updateCommands(active: Bool, hasNext: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = active
        center.pauseCommand.isEnabled = active
        center.togglePlayPauseCommand.isEnabled = active
        center.previousTrackCommand.isEnabled = active
        center.nextTrackCommand.isEnabled = active && hasNext
        center.changePlaybackPositionCommand.isEnabled = active
    }

    private func publishInfo() {
        var info = lastInfo
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ value: String?) {
        artworkTask?.cancel()
        let generation = UUID()
        artworkGeneration = generation
        guard let value, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return
        }

        artworkTask = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      response.statusCode == 200,
                      data.count <= 5 * 1_024 * 1_024,
                      let image = UIImage(data: data),
                      let self, self.artworkGeneration == generation else {
                    return
                }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    image
                }
                self.publishInfo()
            } catch {
                // 封面失败不改变音频状态；新曲目的信息仍然发布。
            }
        }
    }

    deinit {
        artworkTask?.cancel()
        for (command, target) in targets { command.removeTarget(target) }
        for token in notifications {
            NotificationCenter.default.removeObserver(token)
        }
        let taskID = backgroundTask
        if taskID != .invalid {
            Task { @MainActor in
                UIApplication.shared.endBackgroundTask(taskID)
            }
        }
    }
}
