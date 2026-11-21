import Foundation
import XCTest
@testable import XMPro

final class PlaybackSettingsTests: XCTestCase {
    func testDefaults() {
        let settings = PlaybackSettings()
        XCTAssertEqual(settings.quality, "auto")
        XCTAssertEqual(settings.volume, 1)
        XCTAssertEqual(settings.speed, 1)
        XCTAssertFalse(settings.skipTrim)
        XCTAssertEqual(settings.skipMode, "smart")
        XCTAssertEqual(settings.introPermille, 30)
        XCTAssertEqual(settings.outroPermille, 30)
    }

    func testVolumeAndQualityClamping() {
        XCTAssertEqual(PlaybackSettings.normalizeVolume(-1), 0)
        XCTAssertEqual(PlaybackSettings.normalizeVolume(2), 1)
        XCTAssertEqual(PlaybackSettings.normalizeVolume(.nan), 1)
        XCTAssertEqual(PlaybackSettings.normalizeQuality("unknown"), "auto")
        XCTAssertEqual(PlaybackSettings.normalizeQuality("M4A_128"), "m4a_128")
    }

    func testHeadAndTailUseOriginalClampedValues() {
        var settings = PlaybackSettings()
        settings.setTrim(enabled: true, intro: 350, outro: 100, mode: "manual")
        XCTAssertEqual(settings.introPermille, 300)
        XCTAssertEqual(settings.outroPermille, 50)

        settings.setTrim(enabled: true, intro: 900, outro: 900, mode: "other")
        XCTAssertEqual(settings.introPermille, 0)
        XCTAssertEqual(settings.outroPermille, 0)
        XCTAssertEqual(settings.skipMode, "smart")

        settings.setTrim(enabled: true, intro: -1, outro: 900, mode: "manual")
        XCTAssertEqual(settings.introPermille, 0)
        XCTAssertEqual(settings.outroPermille, 400)
    }

    func testSpeedNormalizationIncludesNonFiniteValues() {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(PlaybackSettings.normalizeSpeed(value), 1)
        }
        XCTAssertEqual(PlaybackSettings.normalizeSpeed(0.1), 0.5)
        XCTAssertEqual(PlaybackSettings.normalizeSpeed(9), 3)
        XCTAssertEqual(PlaybackSettings.normalizeSpeed(1.23), 1.25, accuracy: 0.00001)
        XCTAssertEqual(PlaybackSettings.normalizeSpeed(1.21), 1.20, accuracy: 0.00001)
    }

    func testStoredKeysAndRoundTrip() {
        var settings = PlaybackSettings()
        settings.speed = 1.35
        settings.volume = 0.4
        settings.quality = "mp3_32"
        settings.setTrim(enabled: true, intro: 80, outro: 100, mode: "manual")
        XCTAssertEqual(Set(settings.dictionary.keys), Set([
            "quality", "volume", "speed", "skipTrim", "skipMode",
            "introPermille", "outroPermille"
        ]))
        let restored = PlaybackSettings(json: settings.dictionary)
        XCTAssertEqual(restored.speed, settings.speed, accuracy: 0.00001)
        XCTAssertEqual(restored.volume, settings.volume)
        XCTAssertEqual(restored.introPermille, 80)
        XCTAssertEqual(restored.outroPermille, 100)
    }

    func testJSONRoundTripPreservesQualityAndTrimSettings() throws {
        for quality in ["mp3_64", "m4a_24"] {
            var settings = PlaybackSettings()
            settings.quality = quality
            settings.speed = 1.35
            settings.volume = 0.4
            settings.setTrim(enabled: true, intro: 80, outro: 100, mode: "manual")

            let data = try JSONSerialization.data(withJSONObject: settings.dictionary)
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let restored = PlaybackSettings(json: json)

            XCTAssertEqual(restored.quality, quality)
            XCTAssertEqual(restored.skipTrim, settings.skipTrim)
            XCTAssertEqual(restored.skipMode, settings.skipMode)
            XCTAssertEqual(restored.speed, settings.speed, accuracy: 0.00001)
            XCTAssertEqual(restored.volume, settings.volume)
            XCTAssertEqual(restored.introPermille, settings.introPermille)
            XCTAssertEqual(restored.outroPermille, settings.outroPermille)
        }
    }

    func testMissingKeysAndWrongTypesFallBackToDefaults() {
        let defaults = PlaybackSettings()
        let inputs: [[String: Any]] = [
            [:],
            [
                "quality": 42,
                "volume": "0.4",
                "speed": "1.35",
                "skipTrim": "true",
                "skipMode": false,
                "introPermille": "80",
                "outroPermille": "100"
            ]
        ]

        for json in inputs {
            let restored = PlaybackSettings(json: json)
            XCTAssertEqual(restored.quality, defaults.quality)
            XCTAssertEqual(restored.volume, defaults.volume)
            XCTAssertEqual(restored.speed, defaults.speed)
            XCTAssertEqual(restored.skipTrim, defaults.skipTrim)
            XCTAssertEqual(restored.skipMode, defaults.skipMode)
            XCTAssertEqual(restored.introPermille, defaults.introPermille)
            XCTAssertEqual(restored.outroPermille, defaults.outroPermille)
        }
    }
}
