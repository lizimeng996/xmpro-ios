// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import XMPro

final class SmartSkipScannerTests: XCTestCase {
    private func makeSamples(
        sampleRate: Double = 1_000,
        segments: [(amplitude: Float, durationMs: Int)]
    ) -> [Float] {
        var result: [Float] = []
        for (amplitude, durationMs) in segments {
            let count = Int((sampleRate * Double(durationMs) / 1_000.0).rounded())
            result.append(contentsOf: Array(repeating: amplitude, count: count))
        }
        return result
    }

    func testDetectsLongSilenceWithKeepPaddingAndIgnoresShortPause() throws {
        // 0..1000ms 有声，1000..1300ms 短静音（300ms < 500ms），
        // 1300..2300ms 有声，2300..3500ms 长静音（1200ms），3500..4500ms 有声
        let samples = makeSamples(segments: [
            (0.5, 1_000),
            (0.0, 300),
            (0.5, 1_000),
            (0.001, 1_200),
            (0.5, 1_000)
        ])
        let intervals = try SilenceIntervalDetector.detect(
            samples: samples,
            sampleRate: 1_000,
            channels: 1,
            parameters: .default
        )
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0], SilenceInterval(startMs: 2_450, endMs: 3_350))
        XCTAssertEqual(SilenceIntervalDetector.skipTarget(at: 2_500, in: intervals), 3_350)
        XCTAssertNil(SilenceIntervalDetector.skipTarget(at: 2_400, in: intervals))
        XCTAssertNil(SilenceIntervalDetector.skipTarget(at: 3_350, in: intervals))
    }

    func testCacheIsolatesByVersionAndParametersAndEvictsLRU() async {
        let cache = SilenceIntervalCache(maxEntries: 2)
        let k1 = SmartSkipCacheKey(resourceKey: "track-1", resourceVersion: "v1")
        let k2 = SmartSkipCacheKey(resourceKey: "track-1", resourceVersion: "v2")
        let k3 = SmartSkipCacheKey(
            resourceKey: "track-1",
            resourceVersion: "v1",
            parameters: SmartSkipParameters(
                rmsThreshold: 0.02, minSilenceMs: 600, keepPaddingMs: 100, windowMs: 20
            )
        )

        await cache.store([SilenceInterval(startMs: 100, endMs: 500)], for: k1)
        await cache.store([SilenceInterval(startMs: 200, endMs: 600)], for: k2)
        // 访问 k1 使 k2 成为最久未使用
        _ = await cache.intervals(for: k1)
        await cache.store([SilenceInterval(startMs: 300, endMs: 700)], for: k3)

        let count = await cache.count
        XCTAssertEqual(count, 2)
        let hit1 = await cache.intervals(for: k1)
        let hit2 = await cache.intervals(for: k2)
        let hit3 = await cache.intervals(for: k3)
        XCTAssertNotNil(hit1)
        XCTAssertNil(hit2)
        XCTAssertNotNil(hit3)
    }

    func testScannerSkipsRemoteURLsCachesLocalResultsAndSwallowsDecodeFailure() async {
        var decodeCalls = 0
        let scanner = SmartSkipScanner { _, _ in
            decodeCalls += 1
            return [SilenceInterval(startMs: 1_000, endMs: 2_000)]
        }

        let remoteKey = SmartSkipCacheKey(resourceKey: "remote-track")
        let remoteResult = await scanner.scanLocalFile(
            url: URL(string: "https://example.com/audio.m4a")!,
            key: remoteKey
        )
        XCTAssertTrue(remoteResult.isEmpty)
        XCTAssertEqual(decodeCalls, 0)

        let localURL = URL(fileURLWithPath: "/tmp/sample.m4a")
        let localKey = SmartSkipCacheKey(resourceKey: "local-track")
        let first = await scanner.scanLocalFile(url: localURL, key: localKey)
        let second = await scanner.scanLocalFile(url: localURL, key: localKey)
        XCTAssertEqual(first, [SilenceInterval(startMs: 1_000, endMs: 2_000)])
        XCTAssertEqual(second, first)
        XCTAssertEqual(decodeCalls, 1)

        let failingScanner = SmartSkipScanner { _, _ in
            throw NSError(domain: "SmartSkipTest", code: 1)
        }
        let fallback = await failingScanner.scanLocalFile(
            url: localURL, key: SmartSkipCacheKey(resourceKey: "broken")
        )
        XCTAssertTrue(fallback.isEmpty)
    }
}
