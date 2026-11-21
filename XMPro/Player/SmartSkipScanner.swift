// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation

struct SilenceInterval: Equatable, Sendable {
    let startMs: Int64
    let endMs: Int64

    var durationMs: Int64 {
        max(0, endMs - startMs)
    }
}

struct SmartSkipParameters: Equatable, Hashable, Sendable {
    /// 静音判定线性 RMS 阈值（默认约 -40 dBFS = 0.01）。
    let rmsThreshold: Float
    /// 触发跳过的最小连续静音时长（毫秒，默认 500ms）。
    let minSilenceMs: Int64
    /// 静音区间前后各保留的缓冲时长（毫秒，默认 150ms），避免截断辅音起止。
    let keepPaddingMs: Int64
    /// 分析窗口时长（毫秒，默认 20ms）。
    let windowMs: Int64

    static let `default` = SmartSkipParameters(
        rmsThreshold: 0.01,
        minSilenceMs: 500,
        keepPaddingMs: 150,
        windowMs: 20
    )

    var fingerprint: String {
        let rmsMilli = Int((rmsThreshold * 100_000).rounded())
        return "v1:\(rmsMilli):\(minSilenceMs):\(keepPaddingMs):\(windowMs)"
    }
}

struct SmartSkipCacheKey: Equatable, Hashable, Sendable {
    let resourceKey: String
    let resourceVersion: String
    let parametersFingerprint: String

    init(
        resourceKey: String,
        resourceVersion: String = "1",
        parameters: SmartSkipParameters = .default
    ) {
        self.resourceKey = resourceKey
        self.resourceVersion = resourceVersion
        self.parametersFingerprint = parameters.fingerprint
    }
}

/// 纯算法 PCM 静音区间检测器：按固定时间窗口计算 RMS 能量，输出扣除前后保留缓冲后的可跳过区间。
enum SilenceIntervalDetector {
    static func detect(
        samples: [Float],
        sampleRate: Double,
        channels: Int = 1,
        parameters: SmartSkipParameters = .default
    ) throws -> [SilenceInterval] {
        guard sampleRate.isFinite, sampleRate > 0, channels >= 1, !samples.isEmpty else {
            return []
        }
        let framesPerWindow = max(1, Int((sampleRate * Double(parameters.windowMs) / 1_000.0).rounded()))
        let threshold = max(0, parameters.rmsThreshold)

        var silentRunStartFrame: Int?
        var rawIntervals: [SilenceInterval] = []
        let totalFrames = samples.count / channels
        var frameOffset = 0

        while frameOffset < totalFrames {
            try Task.checkCancellation()
            let remainingFrames = totalFrames - frameOffset
            let windowFrames = min(framesPerWindow, remainingFrames)
            let startSample = frameOffset * channels
            let count = min(windowFrames * channels, samples.count - startSample)
            guard count > 0 else { break }

            var sumSquares: Double = 0
            for index in startSample..<(startSample + count) {
                let sample = Double(samples[index])
                sumSquares += sample * sample
            }
            let rms = Float(sqrt(sumSquares / Double(count)))
            let isSilent = rms <= threshold

            if isSilent {
                if silentRunStartFrame == nil {
                    silentRunStartFrame = frameOffset
                }
            } else if let runStart = silentRunStartFrame {
                appendIfQualifies(
                    startFrame: runStart,
                    endFrame: frameOffset,
                    sampleRate: sampleRate,
                    parameters: parameters,
                    into: &rawIntervals
                )
                silentRunStartFrame = nil
            }
            frameOffset += windowFrames
        }

        if let runStart = silentRunStartFrame {
            appendIfQualifies(
                startFrame: runStart,
                endFrame: totalFrames,
                sampleRate: sampleRate,
                parameters: parameters,
                into: &rawIntervals
            )
        }
        return rawIntervals
    }

    /// 查找当前播放位置是否落入某个可跳过静音区间，返回应跳转到的目标毫秒。
    static func skipTarget(
        at positionMs: Int64,
        in intervals: [SilenceInterval]
    ) -> Int64? {
        for interval in intervals {
            if positionMs >= interval.startMs && positionMs < interval.endMs {
                return interval.endMs
            }
        }
        return nil
    }

    private static func appendIfQualifies(
        startFrame: Int,
        endFrame: Int,
        sampleRate: Double,
        parameters: SmartSkipParameters,
        into intervals: inout [SilenceInterval]
    ) {
        let startMs = Int64((Double(startFrame) / sampleRate * 1_000.0).rounded())
        let endMs = Int64((Double(endFrame) / sampleRate * 1_000.0).rounded())
        guard endMs - startMs >= parameters.minSilenceMs else { return }

        let trimmedStart = startMs + parameters.keepPaddingMs
        let trimmedEnd = endMs - parameters.keepPaddingMs
        guard trimmedEnd > trimmedStart else { return }
        intervals.append(SilenceInterval(startMs: trimmedStart, endMs: trimmedEnd))
    }
}

/// 静音区间 LRU 缓存：按资源标识、版本与扫描参数隔离，限制最大缓存条目数。
actor SilenceIntervalCache {
    private let maxEntries: Int
    private var storage: [SmartSkipCacheKey: [SilenceInterval]] = [:]
    private var order: [SmartSkipCacheKey] = []

    init(maxEntries: Int = 64) {
        self.maxEntries = max(1, maxEntries)
    }

    func intervals(for key: SmartSkipCacheKey) -> [SilenceInterval]? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    func store(_ intervals: [SilenceInterval], for key: SmartSkipCacheKey) {
        storage[key] = intervals
        touch(key)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            storage.removeValue(forKey: evicted)
        }
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    var count: Int {
        storage.count
    }

    private func touch(_ key: SmartSkipCacheKey) {
        if let existing = order.firstIndex(of: key) {
            order.remove(at: existing)
        }
        order.append(key)
    }
}

/// 智能跳过静音扫描器：基于 AVAssetReader 解码本地可读取资源为 Float32 PCM，
/// 限制单路并发、支持取消与缓存；任何扫描失败静默返回空区间，绝不影响正常播放。
actor SmartSkipScanner {
    typealias DecodeHandler = @Sendable (URL, SmartSkipParameters) async throws -> [SilenceInterval]

    private let cache: SilenceIntervalCache
    private let decoder: DecodeHandler
    private var activeTask: Task<[SilenceInterval], Never>?
    private var activeKey: SmartSkipCacheKey?

    init(
        cache: SilenceIntervalCache = SilenceIntervalCache(),
        decoder: DecodeHandler? = nil
    ) {
        self.cache = cache
        self.decoder = decoder ?? Self.decodeLocalAsset
    }

    func cachedIntervals(for key: SmartSkipCacheKey) async -> [SilenceInterval]? {
        await cache.intervals(for: key)
    }

    func cancelActiveScan() {
        activeTask?.cancel()
        activeTask = nil
        activeKey = nil
    }

    /// 扫描本地媒体文件；同一时刻最多保留 1 路活跃扫描，新请求会取消旧任务。
    @discardableResult
    func scanLocalFile(
        url: URL,
        key: SmartSkipCacheKey,
        parameters: SmartSkipParameters = .default
    ) async -> [SilenceInterval] {
        if let cached = await cache.intervals(for: key) {
            return cached
        }
        guard url.isFileURL else {
            // 按方案约定：仅处理可读取的本地缓存资源，不阻塞远端流播放。
            return []
        }

        if activeKey != key {
            activeTask?.cancel()
            let decode = decoder
            let task = Task<[SilenceInterval], Never> {
                do {
                    try Task.checkCancellation()
                    let intervals = try await decode(url, parameters)
                    try Task.checkCancellation()
                    return intervals
                } catch {
                    return []
                }
            }
            activeTask = task
            activeKey = key
        }

        guard let task = activeTask else { return [] }
        let result = await task.value
        if !Task.isCancelled && activeKey == key {
            await cache.store(result, for: key)
            activeTask = nil
            activeKey = nil
        }
        return result
    }

    @Sendable static func decodeLocalAsset(
        url: URL,
        parameters: SmartSkipParameters
    ) async throws -> [SilenceInterval] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(
            track: audioTrack, outputSettings: outputSettings
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var allSamples: [Float] = []
        var detectedSampleRate: Double = 44_100
        var detectedChannels = 1
        // 单次扫描内存上限保护（最多约 60 分钟 44.1kHz 单声道 Float32 会过大，按窗口降采样控制）。
        let maxStoredSamples = 8_000_000

        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee {
                if asbd.mSampleRate > 0 { detectedSampleRate = asbd.mSampleRate }
                if asbd.mChannelsPerFrame > 0 { detectedChannels = Int(asbd.mChannelsPerFrame) }
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            let floatCount = length / MemoryLayout<Float>.size
            if allSamples.count + floatCount > maxStoredSamples {
                reader.cancelReading()
                break
            }
            var chunk = [Float](repeating: 0, count: floatCount)
            chunk.withUnsafeMutableBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
                }
            }
            allSamples.append(contentsOf: chunk)
        }

        guard reader.status != .failed else { return [] }
        return try SilenceIntervalDetector.detect(
            samples: allSamples,
            sampleRate: detectedSampleRate,
            channels: detectedChannels,
            parameters: parameters
        )
    }
}
