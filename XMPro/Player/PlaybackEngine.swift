import AVFoundation
import Foundation
import MediaToolbox
import os

enum PlaybackState: String, Sendable {
    case idle, loading, playing, paused, ended, failed
}

struct PlaybackFailure: Error, Equatable, Sendable, LocalizedError {
    let message: String
    let httpStatus: Int?
    var errorDescription: String? { message }

    init(message: String, httpStatus: Int? = nil) {
        self.message = message
        self.httpStatus = httpStatus
    }

    static func map(_ error: NSError, httpStatus: Int? = nil) -> Self {
        let status = httpStatus.flatMap { (400...599).contains($0) ? $0 : nil }
            ?? findHTTPStatus(error, depth: 0)
        if let status {
            return Self(
                message: "播放失败：服务端返回 HTTP \(status)",
                httpStatus: status
            )
        }
        return Self(message: "播放失败：\(error.domain)（\(error.code)）")
    }

    private static func findHTTPStatus(_ error: NSError, depth: Int) -> Int? {
        guard depth < 8 else { return nil }
        for key in ["HTTPStatusCode", "httpStatusCode", "statusCode",
                    "NSHTTPURLResponseStatusCode"] {
            if let number = error.userInfo[key] as? NSNumber,
               (400...599).contains(number.intValue) {
                return number.intValue
            }
        }
        for value in error.userInfo.values {
            if let response = value as? HTTPURLResponse,
               (400...599).contains(response.statusCode) {
                return response.statusCode
            }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return findHTTPStatus(underlying, depth: depth + 1)
        }
        return nil
    }
}

func playbackMilliseconds(_ seconds: Double) -> Int64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64(min(seconds, Double(Int32.max)) * 1_000)
}

struct PlaybackItem: Sendable {
    let id: UUID
    let url: URL
    let headers: [String: String]
    let durationMs: Int64
    let startPositionMs: Int64

    init(
        id: UUID = UUID(),
        url: URL,
        headers: [String: String] = [:],
        durationMs: Int64,
        startPositionMs: Int64
    ) {
        self.id = id
        self.url = url
        self.headers = headers
        self.durationMs = max(0, durationMs)
        let start = max(0, startPositionMs)
        self.startPositionMs = durationMs > 0 ? min(start, durationMs) : start
    }
}

struct PlaybackEngineSnapshot: Sendable {
    var itemID: UUID?
    var state: PlaybackState = .idle
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var failure: PlaybackFailure?
}

enum PlaybackEngineEvent: Sendable {
    case snapshot(PlaybackEngineSnapshot)
    case ended(UUID)
}

@MainActor
protocol PlayerEngine: AnyObject {
    var snapshot: PlaybackEngineSnapshot { get }
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }

    func load(_ item: PlaybackItem) throws
    func play()
    func pause()
    func seek(to positionMs: Int64)
    func setSpeed(_ speed: Double)
    func setVolume(_ volume: Double)
    func setSoundEffect(_ preset: SoundEffectPreset)
    func stop()
}

extension PlayerEngine {
    func setSoundEffect(_ preset: SoundEffectPreset) {}
}

enum PlaybackDriverEvent {
    case prepared(UUID)
    case playing(UUID)
    case waiting(UUID)
    case paused(UUID)
    case time(UUID, positionMs: Int64, durationMs: Int64)
    case ended(UUID)
    case failed(UUID, PlaybackFailure)
    case pauseRequested
}

@MainActor
protocol PlaybackDriver: AnyObject {
    var onEvent: ((PlaybackDriverEvent) -> Void)? { get set }
    func load(_ item: PlaybackItem) throws
    func play()
    func pause()
    func seek(to positionMs: Int64)
    func setSpeed(_ speed: Double)
    func setVolume(_ volume: Double)
    func setSoundEffect(_ preset: SoundEffectPreset)
    func stop()
}

extension PlaybackDriver {
    func setSoundEffect(_ preset: SoundEffectPreset) {}
}

@MainActor
final class PlaybackEngine: PlayerEngine {
    private(set) var snapshot = PlaybackEngineSnapshot()
    var onEvent: ((PlaybackEngineEvent) -> Void)?

    private let driver: any PlaybackDriver
    private var wantsPlayback = false
    private var prepared = false

    init(driver: (any PlaybackDriver)? = nil) {
        self.driver = driver ?? AVPlayerPlaybackDriver()
        self.driver.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    func load(_ item: PlaybackItem) throws {
        wantsPlayback = true
        prepared = false
        snapshot = PlaybackEngineSnapshot(
            itemID: item.id,
            state: .loading,
            positionMs: item.startPositionMs,
            durationMs: item.durationMs
        )
        publish()
        do {
            try driver.load(item)
        } catch {
            let failure = (error as? PlaybackFailure)
                ?? PlaybackFailure.map(error as NSError)
            fail(failure)
            throw failure
        }
    }

    func play() {
        guard snapshot.itemID != nil,
              snapshot.state != .failed else { return }
        wantsPlayback = true
        guard snapshot.state != .playing else { return }
        if snapshot.state == .ended {
            seek(to: 0)
        }
        snapshot.state = .loading
        publish()
        // 未 prepared 时也同步驱动意图并恢复看门狗；prepared 后再次触发播放。
        driver.play()
    }

    func pause() {
        guard snapshot.itemID != nil, snapshot.state != .failed else { return }
        wantsPlayback = false
        driver.pause()
        snapshot.state = .paused
        publish()
    }

    func seek(to positionMs: Int64) {
        guard snapshot.itemID != nil, snapshot.state != .failed else { return }
        var position = max(0, positionMs)
        if snapshot.durationMs > 0 {
            position = min(position, snapshot.durationMs)
        }
        snapshot.positionMs = position
        driver.seek(to: position)
        publish()
    }

    func setSpeed(_ speed: Double) {
        driver.setSpeed(PlaybackSettings.normalizeSpeed(speed))
    }

    func setVolume(_ volume: Double) {
        driver.setVolume(PlaybackSettings.normalizeVolume(volume))
    }

    func setSoundEffect(_ preset: SoundEffectPreset) {
        driver.setSoundEffect(preset)
    }

    func stop() {
        wantsPlayback = false
        prepared = false
        snapshot = PlaybackEngineSnapshot()
        driver.stop()
        publish()
    }

    private func receive(_ event: PlaybackDriverEvent) {
        if case .pauseRequested = event {
            pause()
            return
        }

        let id: UUID
        switch event {
        case let .prepared(value), let .playing(value), let .waiting(value),
             let .paused(value), let .ended(value):
            id = value
        case let .time(value, _, _), let .failed(value, _):
            id = value
        case .pauseRequested:
            return
        }
        guard id == snapshot.itemID, snapshot.state != .failed else { return }

        switch event {
        case .prepared:
            prepared = true
            if wantsPlayback {
                driver.play()
            } else {
                snapshot.state = .paused
                publish()
            }
        case .playing:
            guard wantsPlayback else {
                driver.pause()
                return
            }
            snapshot.state = .playing
            publish()
        case .waiting:
            guard wantsPlayback else { return }
            snapshot.state = .loading
            publish()
        case .paused:
            guard prepared, !wantsPlayback, snapshot.state != .ended else {
                return
            }
            snapshot.state = .paused
            publish()
        case let .time(_, position, duration):
            snapshot.positionMs = max(0, position)
            if duration > 0 { snapshot.durationMs = duration }
            publish()
        case .ended:
            guard snapshot.state != .ended else { return }
            wantsPlayback = false
            snapshot.state = .ended
            publish()
            onEvent?(.ended(id))
        case let .failed(_, failure):
            fail(failure)
        case .pauseRequested:
            break
        }
    }

    private func fail(_ failure: PlaybackFailure) {
        wantsPlayback = false
        snapshot.state = .failed
        snapshot.failure = failure
        driver.pause()
        publish()
    }

    private func publish() {
        onEvent?(.snapshot(snapshot))
    }
}

@MainActor
final class AVPlayerPlaybackDriver: PlaybackDriver {
    var onEvent: ((PlaybackDriverEvent) -> Void)?

    private final class LoadingItem {
        let configuration: PlaybackItem
        let item: AVPlayerItem
        var targetMs: Int64
        var seeking = false
        var ready = false

        init(configuration: PlaybackItem) {
            self.configuration = configuration
            targetMs = configuration.startPositionMs
            item = AVPlayerItem(asset: AVURLAsset(url: configuration.url))
            item.audioTimePitchAlgorithm = .timeDomain
            // S5：在这里接入公开音频处理路径及 PCM 扫描。
            // S3 不安装静音检测器，不把 smart 模式伪装成手动 trim。
        }
    }

    private let player = AVPlayer()
    private let effectEngine = XMAudioEffectEngine()
    private var current: LoadingItem?
    private var speed = 1.0
    private var desiredPlayback = false
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var itemNotifications: [NSObjectProtocol] = []
    private var audioNotifications: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var mixTask: Task<Void, Never>?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        controlObservation = player.observe(
            \.timeControlStatus, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.controlChanged()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 2),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishTime()
            }
        }

        let center = NotificationCenter.default
        audioNotifications.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? NSNumber)?.uintValue
            guard reason == AVAudioSession.RouteChangeReason
                .oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.onEvent?(.pauseRequested)
            }
        })
        audioNotifications.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let type = (notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? NSNumber)?.uintValue
            guard type == AVAudioSession.InterruptionType.began.rawValue else {
                return
            }
            Task { @MainActor [weak self] in
                self?.onEvent?(.pauseRequested)
            }
        })
    }

    func load(_ configuration: PlaybackItem) throws {
        stop()
        guard ["http", "https"].contains(configuration.url.scheme?.lowercased()
                ?? "") else {
            throw PlaybackFailure(message: "播放失败：无效的音频地址")
        }
        // AVURLAsset 没有公开的任意 HTTP header 初始化 API。
        // 禁止使用 AVURLAssetHTTPHeaderFieldsKey 等未公开选项，也不静默丢头。
        guard configuration.headers.isEmpty else {
            throw PlaybackFailure(message: "播放失败：音频地址要求暂不支持的附加请求头")
        }

        let loading = LoadingItem(configuration: configuration)
        current = loading
        desiredPlayback = true
        attachAudioMix(to: loading.item, id: configuration.id)
        player.replaceCurrentItem(with: loading.item)
        armWatchdog(id: configuration.id)

        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: loading.item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.current?.configuration.id == configuration.id else {
                    return
                }
                self.desiredPlayback = false
                self.watchdog?.cancel()
                self.watchdog = nil
                self.publishTime()
                self.onEvent?(.ended(configuration.id))
            }
        })
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: loading.item, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? NSError
            Task { @MainActor [weak self] in
                self?.reportFailure(
                    id: configuration.id,
                    error: error ?? NSError(domain: "AVPlayerItem", code: -1)
                )
            }
        })
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: loading.item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.desiredPlayback,
                      self.current?.configuration.id == configuration.id else {
                    return
                }
                self.onEvent?(.waiting(configuration.id))
                self.armWatchdog(id: configuration.id)
            }
        })

        statusObservation = loading.item.observe(
            \.status, options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.itemStatusChanged(id: configuration.id)
            }
        }
    }

    func play() {
        desiredPlayback = true
        guard let current else { return }
        guard current.ready else {
            armWatchdog(id: current.configuration.id)
            return
        }
        player.playImmediately(atRate: Float(speed))
        armWatchdog(id: current.configuration.id)
    }

    func pause() {
        desiredPlayback = false
        watchdog?.cancel()
        watchdog = nil
        player.pause()
    }

    func seek(to positionMs: Int64) {
        guard let current else { return }
        if !current.ready {
            current.targetMs = max(0, positionMs)
            itemStatusChanged(id: current.configuration.id)
            return
        }
        let id = current.configuration.id
        player.seek(
            to: CMTime(value: max(0, positionMs), timescale: 1_000),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor [weak self] in
                guard self?.current?.configuration.id == id else { return }
                self?.publishTime()
            }
        }
    }

    func setSpeed(_ speed: Double) {
        self.speed = PlaybackSettings.normalizeSpeed(speed)
        if desiredPlayback, current?.ready == true {
            player.rate = Float(self.speed)
        }
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(PlaybackSettings.normalizeVolume(volume))
    }

    func setSoundEffect(_ preset: SoundEffectPreset) {
        effectEngine.setPreset(preset)
    }

    func stop() {
        desiredPlayback = false
        watchdog?.cancel()
        watchdog = nil
        mixTask?.cancel()
        mixTask = nil
        statusObservation = nil
        current = nil
        for token in itemNotifications {
            NotificationCenter.default.removeObserver(token)
        }
        itemNotifications.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func attachAudioMix(to item: AVPlayerItem, id: UUID) {
        mixTask?.cancel()
        let effectEngine = self.effectEngine
        mixTask = Task { [weak self, weak item] in
            guard let item else { return }
            guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio),
                  let audioTrack = tracks.first,
                  !Task.isCancelled else {
                return
            }
            guard let mix = effectEngine.makeAudioMix(for: audioTrack) else { return }
            await MainActor.run { [weak self, weak item] in
                guard let self, let item,
                      self.current?.configuration.id == id else { return }
                item.audioMix = mix
            }
        }
    }

    private func itemStatusChanged(id: UUID) {
        guard let current, current.configuration.id == id else { return }
        switch current.item.status {
        case .failed:
            reportFailure(
                id: id,
                error: current.item.error as NSError?
                    ?? NSError(domain: "AVPlayerItem", code: -1)
            )
        case .readyToPlay:
            guard !current.ready, !current.seeking else { return }
            current.seeking = true
            let target = current.targetMs
            // 开始位置属于 LoadingItem；ready 后完成精确 seek 才发 prepared。
            // 绝不在 replaceCurrentItem/prepare 后立即发一次可能丢失的 seek。
            player.seek(
                to: CMTime(value: target, timescale: 1_000),
                toleranceBefore: .zero, toleranceAfter: .zero
            ) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, let live = self.current,
                          live.configuration.id == id else { return }
                    live.seeking = false
                    guard finished else {
                        self.reportFailure(
                            id: id,
                            error: NSError(domain: "InitialSeek", code: -1)
                        )
                        return
                    }
                    if live.targetMs != target {
                        self.itemStatusChanged(id: id)
                        return
                    }
                    live.ready = true
                    self.watchdog?.cancel()
                    self.watchdog = nil
                    self.onEvent?(.prepared(id))
                    self.publishTime()
                }
            }
        case .unknown:
            break
        @unknown default:
            reportFailure(
                id: id, error: NSError(domain: "AVPlayerItemStatus", code: -1)
            )
        }
    }

    private func controlChanged() {
        guard let current, current.ready else { return }
        let id = current.configuration.id
        switch player.timeControlStatus {
        case .playing:
            watchdog?.cancel()
            watchdog = nil
            onEvent?(.playing(id))
        case .waitingToPlayAtSpecifiedRate:
            guard desiredPlayback else { return }
            onEvent?(.waiting(id))
            armWatchdog(id: id)
        case .paused:
            onEvent?(.paused(id))
        @unknown default:
            break
        }
    }

    private func publishTime() {
        guard let current, current.ready else { return }
        onEvent?(.time(
            current.configuration.id,
            positionMs: playbackMilliseconds(player.currentTime().seconds),
            durationMs: playbackMilliseconds(current.item.duration.seconds)
        ))
    }

    private func reportFailure(id: UUID, error: NSError) {
        guard let current, current.configuration.id == id else { return }
        desiredPlayback = false
        watchdog?.cancel()
        watchdog = nil
        player.pause()
        let status = current.item.errorLog()?.events.reversed()
            .map(\.errorStatusCode).first { (400...599).contains($0) }
        onEvent?(.failed(id, PlaybackFailure.map(error, httpStatus: status)))
    }

    private func armWatchdog(id: UUID) {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 45_000_000_000)
            } catch {
                return
            }
            guard let self, self.desiredPlayback,
                  self.current?.configuration.id == id else { return }
            if self.player.timeControlStatus == .playing {
                // 释放已到期任务，允许后续卡顿重新启动看门狗。
                self.watchdog = nil
                return
            }
            self.reportFailure(
                id: id, error: NSError(domain: NSURLErrorDomain,
                                      code: NSURLErrorTimedOut)
            )
        }
    }

    deinit {
        watchdog?.cancel()
        mixTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for token in itemNotifications + audioNotifications {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

// MARK: - 实时音频音效 DSP 处理器（公开 API：MTAudioProcessingTap + AVMutableAudioMix）

/// 线程安全的实时音频效果器：支持人声增强、重低音、3D 环绕、音量均衡，播放中可无缝切换。
final class XMAudioEffectEngine: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: SoundEffectPreset.off)

    var preset: SoundEffectPreset {
        lock.withLock { $0 }
    }

    func setPreset(_ preset: SoundEffectPreset) {
        lock.withLock { $0 = preset }
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVMutableAudioMix? {
        let context = TapContext(engine: self)
        let unmanaged = Unmanaged.passRetained(context)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: unmanaged.toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<TapContext>.fromOpaque(storage).release()
            },
            prepare: { tap, _, processingFormat in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.configure(format: processingFormat.pointee)
            },
            unprepare: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.reset()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut
                )
                guard status == noErr else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.process(bufferList: bufferListInOut, frameCount: Int(numberFramesOut.pointee))
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let createdTap = tap else {
            unmanaged.release()
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = createdTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        mutating func reset() { z1 = 0; z2 = 0 }

        @inline(__always)
        mutating func step(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        static func highPass(sampleRate: Double, freq: Double, q: Double = 0.707) -> Biquad {
            let w0 = 2.0 * .pi * min(freq, sampleRate * 0.45) / sampleRate
            let cosw = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha
            return Biquad(
                b0: Float(((1.0 + cosw) * 0.5) / a0),
                b1: Float((-(1.0 + cosw)) / a0),
                b2: Float(((1.0 + cosw) * 0.5) / a0),
                a1: Float((-2.0 * cosw) / a0),
                a2: Float((1.0 - alpha) / a0)
            )
        }

        static func peaking(sampleRate: Double, freq: Double, q: Double, gainDB: Double) -> Biquad {
            let a = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * .pi * min(freq, sampleRate * 0.45) / sampleRate
            let cosw = cos(w0)
            let alpha = sin(w0) / (2.0 * q)
            let a0 = 1.0 + alpha / a
            return Biquad(
                b0: Float((1.0 + alpha * a) / a0),
                b1: Float((-2.0 * cosw) / a0),
                b2: Float((1.0 - alpha * a) / a0),
                a1: Float((-2.0 * cosw) / a0),
                a2: Float((1.0 - alpha / a) / a0)
            )
        }

        static func lowShelf(sampleRate: Double, freq: Double, gainDB: Double) -> Biquad {
            let a = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * .pi * min(freq, sampleRate * 0.45) / sampleRate
            let cosw = cos(w0)
            let sinw = sin(w0)
            let twoSqrtAAlpha = 2.0 * sqrt(a) * (sinw / 2.0 * sqrt(2.0))
            let a0 = (a + 1.0) + (a - 1.0) * cosw + twoSqrtAAlpha
            return Biquad(
                b0: Float((a * ((a + 1.0) - (a - 1.0) * cosw + twoSqrtAAlpha)) / a0),
                b1: Float((2.0 * a * ((a - 1.0) - (a + 1.0) * cosw)) / a0),
                b2: Float((a * ((a + 1.0) - (a - 1.0) * cosw - twoSqrtAAlpha)) / a0),
                a1: Float((-2.0 * ((a - 1.0) + (a + 1.0) * cosw)) / a0),
                a2: Float(((a + 1.0) + (a - 1.0) * cosw - twoSqrtAAlpha) / a0)
            )
        }

        static func highShelf(sampleRate: Double, freq: Double, gainDB: Double) -> Biquad {
            let a = pow(10.0, gainDB / 40.0)
            let w0 = 2.0 * .pi * min(freq, sampleRate * 0.45) / sampleRate
            let cosw = cos(w0)
            let sinw = sin(w0)
            let twoSqrtAAlpha = 2.0 * sqrt(a) * (sinw / 2.0 * sqrt(2.0))
            let a0 = (a + 1.0) - (a - 1.0) * cosw + twoSqrtAAlpha
            return Biquad(
                b0: Float((a * ((a + 1.0) + (a - 1.0) * cosw + twoSqrtAAlpha)) / a0),
                b1: Float((-2.0 * a * ((a - 1.0) + (a + 1.0) * cosw)) / a0),
                b2: Float((a * ((a + 1.0) + (a - 1.0) * cosw - twoSqrtAAlpha)) / a0),
                a1: Float((2.0 * ((a - 1.0) - (a + 1.0) * cosw)) / a0),
                a2: Float(((a + 1.0) - (a - 1.0) * cosw - twoSqrtAAlpha) / a0)
            )
        }
    }

    private final class TapContext {
        let engine: XMAudioEffectEngine
        var sampleRate: Double = 44_100
        var isFloat32 = false
        var isNonInterleaved = true
        var activePreset: SoundEffectPreset = .off

        // 每声道滤波器组（最多 2 声道）
        var f1: [Biquad] = []
        var f2: [Biquad] = []
        var f3: [Biquad] = []

        // 3D 环绕延迟线
        var delayBuffer: [Float] = []
        var delayIndex: Int = 0

        // 音量均衡包络状态
        var rmsEnvelope: Float = 0.05

        init(engine: XMAudioEffectEngine) {
            self.engine = engine
        }

        func configure(format: AudioStreamBasicDescription) {
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
            isFloat32 = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
            isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
            let delaySamples = max(64, Int(sampleRate * 0.014)) // ~14ms 空间延迟
            delayBuffer = Array(repeating: 0, count: delaySamples)
            delayIndex = 0
            rmsEnvelope = 0.05
            rebuildFilters(for: engine.preset, channels: max(1, Int(format.mChannelsPerFrame)))
        }

        func reset() {
            for i in f1.indices { f1[i].reset() }
            for i in f2.indices { f2[i].reset() }
            for i in f3.indices { f3[i].reset() }
            for i in delayBuffer.indices { delayBuffer[i] = 0 }
            delayIndex = 0
            rmsEnvelope = 0.05
        }

        private func rebuildFilters(for preset: SoundEffectPreset, channels: Int) {
            activePreset = preset
            let ch = max(1, min(channels, 2))
            switch preset {
            case .off, .loudness:
                f1 = []; f2 = []; f3 = []
            case .vocal:
                f1 = Array(repeating: .highPass(sampleRate: sampleRate, freq: 120), count: ch)
                f2 = Array(repeating: .peaking(sampleRate: sampleRate, freq: 2_200, q: 1.0, gainDB: 5.5), count: ch)
                f3 = Array(repeating: .peaking(sampleRate: sampleRate, freq: 5_000, q: 1.2, gainDB: 2.5), count: ch)
            case .bass:
                f1 = Array(repeating: .lowShelf(sampleRate: sampleRate, freq: 100, gainDB: 7.0), count: ch)
                f2 = Array(repeating: .peaking(sampleRate: sampleRate, freq: 220, q: 0.9, gainDB: 2.5), count: ch)
                f3 = []
            case .surround3D:
                f1 = Array(repeating: .highShelf(sampleRate: sampleRate, freq: 7_500, gainDB: 3.0), count: ch)
                f2 = []; f3 = []
            }
        }

        func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
            guard isFloat32, frameCount > 0 else { return }
            let targetPreset = engine.preset
            guard targetPreset != .off else {
                if activePreset != .off { activePreset = .off }
                return
            }

            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard !buffers.isEmpty else { return }

            let channelCount = isNonInterleaved ? buffers.count : Int(buffers[0].mNumberChannels)
            if targetPreset != activePreset || (f1.isEmpty && (targetPreset == .vocal || targetPreset == .bass || targetPreset == .surround3D)) {
                rebuildFilters(for: targetPreset, channels: channelCount)
            }

            if isNonInterleaved {
                processNonInterleaved(buffers: buffers, frameCount: frameCount, preset: targetPreset)
            } else {
                processInterleaved(buffer: buffers[0], channels: channelCount, frameCount: frameCount, preset: targetPreset)
            }
        }

        private func processNonInterleaved(
            buffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            preset: SoundEffectPreset
        ) {
            switch preset {
            case .off:
                return
            case .vocal, .bass:
                for ch in 0..<min(buffers.count, 2) {
                    guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frameCount {
                        var s = ptr[i]
                        if ch < f1.count { s = f1[ch].step(s) }
                        if ch < f2.count { s = f2[ch].step(s) }
                        if ch < f3.count { s = f3[ch].step(s) }
                        ptr[i] = softClip(s)
                    }
                }
            case .surround3D:
                if buffers.count >= 2,
                   let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                   let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    let delayLen = delayBuffer.count
                    for i in 0..<frameCount {
                        let l = left[i]
                        let r = right[i]
                        let mid = (l + r) * 0.5
                        let side = (l - r) * 0.5
                        let delayed = delayLen > 0 ? delayBuffer[delayIndex] : 0
                        if delayLen > 0 {
                            delayBuffer[delayIndex] = side * 0.45 + mid * 0.18
                            delayIndex = (delayIndex + 1) % delayLen
                        }
                        var outL = mid + side * 1.85 + delayed * 0.25
                        var outR = mid - side * 1.85 - delayed * 0.25
                        if !f1.isEmpty { outL = f1[0].step(outL) }
                        if f1.count > 1 { outR = f1[1].step(outR) }
                        left[i] = softClip(outL)
                        right[i] = softClip(outR)
                    }
                } else if let mono = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<frameCount {
                        let s = !f1.isEmpty ? f1[0].step(mono[i]) : mono[i]
                        mono[i] = softClip(s)
                    }
                }
            case .loudness:
                var sumSq: Float = 0
                var count = 0
                for ch in 0..<buffers.count {
                    guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frameCount {
                        let v = ptr[i]
                        sumSq += v * v
                    }
                    count += frameCount
                }
                guard count > 0 else { return }
                let rms = sqrt(sumSq / Float(count))
                let alpha: Float = rms > rmsEnvelope ? 0.25 : 0.04
                rmsEnvelope = rmsEnvelope * (1 - alpha) + rms * alpha
                let targetRMS: Float = 0.16 // ~ -16 dBFS
                let gain = min(max(targetRMS / max(rmsEnvelope, 0.015), 0.5), 3.2)
                for ch in 0..<buffers.count {
                    guard let ptr = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frameCount {
                        ptr[i] = softClip(ptr[i] * gain)
                    }
                }
            }
        }

        private func processInterleaved(
            buffer: AudioBuffer,
            channels: Int,
            frameCount: Int,
            preset: SoundEffectPreset
        ) {
            guard channels > 0, let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
            let total = frameCount * channels
            switch preset {
            case .off:
                return
            case .vocal, .bass:
                for i in 0..<frameCount {
                    for ch in 0..<min(channels, 2) {
                        let idx = i * channels + ch
                        var s = ptr[idx]
                        if ch < f1.count { s = f1[ch].step(s) }
                        if ch < f2.count { s = f2[ch].step(s) }
                        if ch < f3.count { s = f3[ch].step(s) }
                        ptr[idx] = softClip(s)
                    }
                }
            case .surround3D:
                guard channels >= 2 else { return }
                let delayLen = delayBuffer.count
                for i in 0..<frameCount {
                    let lIdx = i * channels
                    let rIdx = lIdx + 1
                    let mid = (ptr[lIdx] + ptr[rIdx]) * 0.5
                    let side = (ptr[lIdx] - ptr[rIdx]) * 0.5
                    let delayed = delayLen > 0 ? delayBuffer[delayIndex] : 0
                    if delayLen > 0 {
                        delayBuffer[delayIndex] = side * 0.45 + mid * 0.18
                        delayIndex = (delayIndex + 1) % delayLen
                    }
                    var outL = mid + side * 1.85 + delayed * 0.25
                    var outR = mid - side * 1.85 - delayed * 0.25
                    if !f1.isEmpty { outL = f1[0].step(outL) }
                    if f1.count > 1 { outR = f1[1].step(outR) }
                    ptr[lIdx] = softClip(outL)
                    ptr[rIdx] = softClip(outR)
                }
            case .loudness:
                var sumSq: Float = 0
                for i in 0..<total { sumSq += ptr[i] * ptr[i] }
                let rms = sqrt(sumSq / Float(max(1, total)))
                let alpha: Float = rms > rmsEnvelope ? 0.25 : 0.04
                rmsEnvelope = rmsEnvelope * (1 - alpha) + rms * alpha
                let gain = min(max(0.16 / max(rmsEnvelope, 0.015), 0.5), 3.2)
                for i in 0..<total {
                    ptr[i] = softClip(ptr[i] * gain)
                }
            }
        }

        @inline(__always)
        private func softClip(_ x: Float) -> Float {
            if abs(x) <= 0.85 { return x }
            return tanhf(x)
        }
    }
}
