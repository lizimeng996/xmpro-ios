import Foundation

struct PlaybackSettings: Equatable, Sendable {
    var quality = "auto"
    var volume = 1.0
    var speed = 1.0
    var skipTrim = false
    var skipMode = "smart"
    var introPermille = 30
    var outroPermille = 30

    init(json: [String: Any] = [:]) {
        if let value = json["quality"] as? String {
            quality = Self.normalizeQuality(value)
        }
        volume = Self.normalizeVolume(
            (json["volume"] as? NSNumber)?.doubleValue ?? 1
        )
        speed = Self.normalizeSpeed(
            (json["speed"] as? NSNumber)?.doubleValue ?? 1
        )
        setTrim(
            enabled: (json["skipTrim"] as? Bool) ?? false,
            intro: (json["introPermille"] as? NSNumber)?.intValue ?? 30,
            outro: (json["outroPermille"] as? NSNumber)?.intValue ?? 30,
            mode: json["skipMode"] as? String ?? "smart"
        )
    }

    static func normalizeSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        let clamped = min(3, max(0.5, value))
        return min(3, max(0.5, (clamped / 0.05).rounded() * 0.05))
    }

    static func normalizeVolume(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 1
    }

    static func normalizeQuality(_ value: String) -> String {
        let lowered = value.lowercased()
        return lowered == "auto" || ProtocolConfig.qualities.contains(lowered)
            ? lowered : "auto"
    }

    mutating func setTrim(
        enabled: Bool, intro: Int, outro: Int, mode: String
    ) {
        let head = min(400, max(0, intro))
        let tail = min(400, max(0, outro))
        skipTrim = enabled
        skipMode = mode == "manual" ? "manual" : "smart"
        // 严格复用 Kotlin 的两个原始钳制值，不能先改 head 再计算 tail。
        introPermille = min(head, 400 - tail)
        outroPermille = min(tail, 400 - head)
    }

    var dictionary: [String: Any] {
        [
            "quality": quality,
            "volume": volume,
            "speed": speed,
            "skipTrim": skipTrim,
            "skipMode": skipMode,
            "introPermille": introPermille,
            "outroPermille": outroPermille
        ]
    }
}
