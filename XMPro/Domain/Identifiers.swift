
import Foundation

func xmlyIdentifier(_ value: String) throws -> String {
    guard ProtocolBytes.fullMatch(#"^(?:xmly:)?([1-9][0-9]{0,18})$"#, value) else {
        throw XmlyError.failure(
            code: .invalidId,
            message: "喜马拉雅 ID 必须是正整数或 xmly:正整数",
            definitive: true
        )
    }
    return value.hasPrefix("xmly:") ? String(value.dropFirst(5)) : value
}

func xmlyPositive(_ value: Any?) -> Int? {
    let text: String
    if let string = value as? String {
        text = string
    } else if let number = value as? NSNumber {
        guard !xmlyIsBoolean(number),
              ["s", "i", "l", "q", "S", "I", "L", "Q", "c", "C"]
                .contains(String(cString: number.objCType)) else {
            return nil
        }
        text = number.stringValue
    } else {
        return nil
    }

    // Kotlin 只接受 String/Int，范围 1...Int.MAX_VALUE；Swift 侧以 Int32.max
    // 为同一上界，超限的 64 位数值同样返回 nil。
    guard !text.isEmpty,
          text.utf8.allSatisfy({ (48...57).contains($0) }),
          let result = Int(text),
          result >= 1,
          result <= Int(Int32.max) else {
        return nil
    }
    return result
}

func mediaUri(_ value: String) throws -> String {
    guard let components = xmlyHTTPComponents(value),
          let host = components.host?.lowercased() else {
        // 与 Kotlin 逐字一致：文案“音频地址无效”，definitive 取默认值 false。
        throw XmlyError.failure(
            code: .invalidMedia,
            message: "音频地址无效"
        )
    }

    let trusted = xmlyHost(host, belongsTo: "xmcdn.com")
        || xmlyHost(host, belongsTo: "ximalaya.com")
    if components.scheme?.lowercased() == "http",
       trusted,
       components.port == nil || components.port == 80,
       value.hasPrefix("http://") {
        // 与 Kotlin replaceFirst("http://", "https://") 同义：仅小写前缀升级；
        // 大写 "HTTP://" 形式的地址保持原样。
        return "https://" + String(value.dropFirst(7))
    }
    return value
}

func coverUrl(_ raw: [String: Any]) -> String? {
    let keys = [
        "coverLarge", "coverMiddle", "coverSmall", "cover_path",
        "album_cover_path", "cover_url", "albumImage",
        "coverOrigin", "coverPath", "coverWebLarge", "coverWebMiddle",
        "albumCoverPath", "coverUrl", "cover", "pic"
    ]
    for key in keys {
        guard let original = raw[key] as? String,
              !original.isEmpty,
              original.utf16.count <= 16_384,
              !original.unicodeScalars.contains(where: { $0.value <= 0x20 }) else {
            continue
        }

        let value = original.hasPrefix("//") ? "https:" + original : original
        guard let components = xmlyHTTPComponents(value),
              let host = components.host?.lowercased() else {
            continue
        }
        if components.scheme?.lowercased() == "http",
           xmlyHost(host, belongsTo: "xmcdn.com"),
           value.hasPrefix("http://") {
            return "https://" + String(value.dropFirst(7))
        }
        return value
    }
    return nil
}

func publicRaw(_ raw: [String: Any]) -> [String: Any] {
    let allowed: Set<String> = [
        "id", "trackId", "albumId", "album_id", "title", "nickname",
        "albumTitle", "album_title", "duration", "orderNo", "orderNum",
        "order_no", "episode", "sequence", "index", "officialPosition",
        "isPaid", "is_paid", "isAuthorized", "intro", "coverLarge",
        "coverMiddle", "coverSmall", "cover_path", "album_cover_path",
        "cover_url", "albumImage", "tracks", "totalCount", "total",
        "year", "date",
        // "direction"：历史同步从 track.raw 取播放方向（Kotlin XmlyHistory：
        // Number 取整，非 0/1 报 invalid_history；非 Number 取 0）；
        // S2 Round B1 起保留，NSNumber 原样保留。
        "direction"
    ]

    var result: [String: Any] = [:]
    for key in allowed {
        if let string = raw[key] as? String {
            result[key] = String(string)
        } else if let number = raw[key] as? NSNumber {
            result[key] = number.copy()
        }
    }
    if let user = raw["userInfo"] as? [String: Any],
       let nickname = user["nickname"] as? String {
        result["userInfo"] = ["nickname": String(nickname)]
    }
    return result
}

// Foundation 的布尔 NSNumber 与普通数值 NSNumber 使用不同的具体类型。
func xmlyIsBoolean(_ number: NSNumber) -> Bool {
    type(of: number) == type(of: NSNumber(value: true))
}

private func xmlyHost(_ host: String, belongsTo domain: String) -> Bool {
    host == domain || host.hasSuffix("." + domain)
}

private func xmlyHTTPComponents(_ value: String) -> URLComponents? {
    guard !value.isEmpty,
          value.utf16.count <= 16_384,
          !value.unicodeScalars.contains(where: { $0.value <= 0x20 }),
          let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = components.host,
          !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.url != nil else {
        return nil
    }
    return components
}

// MARK: - 与 Android org.json 的 opt* 转换对齐的解析辅助
//
// 转换表（以 Kotlin 实际运行时的 org.json 为准，构造器的范围校验是另一层
// 规则，两层不要混淆）：
// - Number → Java Number.intValue()/longValue()：整数向 32/64 位回绕；
//   浮点向零截断，超范围饱和到 Int32/Int64 边界（NaN 取 0）。
// - String → Integer.parseLong/parseInt：严格整数解析（不接受 "60.9"、"6e1"、
//   空白与超限）；失败取默认值。
// - Boolean → optBoolean：布尔取本身；字符串按 "true"／"false"（忽略大小写）
//   解析；数值与其他类型取默认值。
// Swift 侧 JSONSerialization 只产 NSNumber／String，以下辅助复现同一转换表，
// 供 Quota 与 AccountSummary 等跨端读取使用。

/// org.json optInt：数值按 Java intValue() 转换；字符串严格解析；其余取默认值。
func xmlyJsonInt(_ value: Any?, default fallback: Int) -> Int {
    if let number = value as? NSNumber, !xmlyIsBoolean(number) {
        let type = String(cString: number.objCType)
        if type == "f" || type == "d" {
            // Java (int)double：向零截断，超范围饱和（NaN 取 0）。
            let truncated = number.doubleValue.rounded(.towardZero)
            if truncated.isNaN { return 0 }
            if truncated >= Double(Int32.max) { return Int(Int32.max) }
            if truncated <= Double(Int32.min) { return Int(Int32.min) }
            return Int(truncated)
        }
        // Java Number.intValue()：64 位整数向 32 位回绕。
        return Int(Int32(truncatingIfNeeded: number.intValue))
    }
    if let text = value as? String,
       let parsed = Int(text),
       parsed >= Int(Int32.min),
       parsed <= Int(Int32.max) {
        return parsed
    }
    return fallback
}

/// org.json optLong：数值按 Java longValue() 转换；字符串严格解析；其余取默认值。
func xmlyJsonLong(_ value: Any?, default fallback: Int64) -> Int64 {
    if let number = value as? NSNumber, !xmlyIsBoolean(number) {
        let type = String(cString: number.objCType)
        if type == "f" || type == "d" {
            let truncated = number.doubleValue.rounded(.towardZero)
            if truncated.isNaN { return 0 }
            if truncated >= 9_223_372_036_854_775_808.0 { return Int64.max }
            if truncated <= -9_223_372_036_854_775_808.0 { return Int64.min }
            return Int64(truncated)
        }
        return number.int64Value
    }
    if let text = value as? String, let parsed = Int64(text) {
        return parsed
    }
    return fallback
}

/// org.json optBoolean：布尔取本身；字符串按 "true"／"false"（忽略大小写）
/// 解析，其他字符串与数值取默认值。
func xmlyJsonBool(_ value: Any?, default fallback: Bool) -> Bool {
    if let number = value as? NSNumber, xmlyIsBoolean(number) {
        return number.boolValue
    }
    if let text = value as? String {
        switch text.lowercased() {
        case "true": return true
        case "false": return false
        default: return fallback
        }
    }
    return fallback
}
