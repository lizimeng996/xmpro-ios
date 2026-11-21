import Foundation

struct UserPage: Sendable {
    let uid: String
    var nickname: String = ""
    var avatarUrl: String? = nil
    var intro: String = ""
    var followers: Int = 0
    var following: Int = 0
    var albums: [Album] = []
    var totalAlbums: Int = 0
}

struct SocialUser: Sendable {
    let uid: String
    var nickname: String = ""
    var avatarUrl: String? = nil
    var followers: Int = 0
    var albums: Int = 0
    var intro: String = ""
}

struct UserProfile: Sendable {
    let uid: String
    var nickname: String = ""
    var avatarUrl: String? = nil
    var intro: String = ""
    var followers: Int? = nil
    var following: Int? = nil
    var subscriptions: Int? = nil
}

struct SocialCounts: Equatable, Sendable {
    var following: Int = 0
    var followers: Int = 0
    var subscriptions: Int = 0
    var albums: Int = 0
    var tracks: Int = 0
}

func cdnUrl(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

    // Kotlin String.length 按 UTF-16 代码单元计数。
    // 字符检查沿用原端规则：规范化后的字符编码不得 <= 0x20。
    guard !value.isEmpty,
          value.utf16.count <= 16_384,
          !value.unicodeScalars.contains(where: { $0.value <= 0x20 }) else {
        return nil
    }

    if value.hasPrefix("//") {
        return "https:" + value
    }
    if value.hasPrefix("http://") {
        return "https://" + String(value.dropFirst(7))
    }
    if value.hasPrefix("https://") {
        return value
    }
    return "https://imagev2.xmcdn.com/"
        + String(value.drop(while: { $0 == "/" }))
}
