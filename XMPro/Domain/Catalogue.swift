
import Foundation

// raw 对外维持 Kotlin 的字典形状，内部使用值类型，避免 Any 跨并发域共享。
private indirect enum CatalogueValue: Sendable, Codable {
    case string(String)
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case decimal(Double)
    case object([String: CatalogueValue])

    init(_ value: Any) throws {
        if let string = value as? String {
            self = .string(string)
        } else if let number = value as? NSNumber {
            if xmlyIsBoolean(number) {
                self = .bool(number.boolValue)
            } else if let integer = Int64(number.stringValue) {
                self = .integer(integer)
            } else if let unsigned = UInt64(number.stringValue) {
                self = .unsigned(unsigned)
            } else if number.doubleValue.isFinite {
                self = .decimal(number.doubleValue)
            } else {
                throw Self.invalid
            }
        } else if let object = value as? [String: Any] {
            self = .object(try object.mapValues { try CatalogueValue($0) })
        } else {
            throw Self.invalid
        }
    }

    var value: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .integer(let value): return value
        case .unsigned(let value): return value
        case .decimal(let value): return value
        case .object(let value): return value.mapValues(\.value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .decimal(value)
        } else if let value = try? container.decode([String: CatalogueValue].self) {
            self = .object(value)
        } else {
            throw Self.invalid
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    static func sanitized(_ raw: [String: Any?]) throws -> [String: CatalogueValue] {
        let values = raw.mapValues { $0 ?? NSNull() }
        return try publicRaw(values).mapValues { try CatalogueValue($0) }
    }

    private static var invalid: XmlyError {
        .failure(code: .invalidJSON, message: "公开元数据格式无效")
    }
}

struct Track: Sendable, Codable {
    let id: String
    var number: String { String(id.dropFirst(5)) }
    var albumKey: String {
        albumId.isEmpty ? "" : (try? xmlyIdentifier(albumId)) ?? ""
    }

    let title: String
    let artist: String
    let album: String
    let albumId: String
    let duration: Double
    let orderNo: Int?
    let episode: Int?
    let isPaid: Bool?
    let isAuthorized: Bool?
    let coverUrl: String?
    let intro: String
    private let metadata: [String: CatalogueValue]

    var raw: [String: Any?] {
        metadata.mapValues { Optional($0.value) }
    }

    init(
        rawId: String,
        title: String = "",
        artist: String = "",
        album: String = "",
        albumId: String = "",
        duration: Double = 0,
        orderNo: Int? = nil,
        episode: Int? = nil,
        isPaid: Bool? = nil,
        isAuthorized: Bool? = nil,
        coverUrl: String? = nil,
        intro: String = "",
        raw: [String: Any?] = [:]
    ) throws {
        id = "xmly:" + (try xmlyIdentifier(rawId))
        // Kotlin toJson 用 albumKey（去前缀后的规范形式）；此处直接存规范值，
        // 使 toJson 与 Kotlin 一致。非法 albumId 在此抛错，与 Kotlin 构造时抛错一致。
        self.albumId = albumId.isEmpty ? "" : try xmlyIdentifier(albumId)
        guard duration.isFinite else {
            throw XmlyError.failure(
                code: .invalidResponse, message: "音轨时长无效"
            )
        }
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.orderNo = orderNo
        self.episode = episode
        self.isPaid = isPaid
        self.isAuthorized = isAuthorized
        self.coverUrl = coverUrl
        self.intro = intro
        metadata = try CatalogueValue.sanitized(raw)
    }

    func toJson() -> [String: Any] {
        // JSON 对象没有有序键语义；字段及显式 null 与 Kotlin 保持一致。
        [
            "id": id,
            "title": title,
            "artist": artist,
            "album": album,
            "album_id": albumId,
            "duration": duration,
            "order_no": orderNo.map { $0 as Any } ?? NSNull(),
            "episode": episode.map { $0 as Any } ?? NSNull(),
            "is_paid": isPaid.map { $0 as Any } ?? NSNull(),
            "is_authorized": isAuthorized.map { $0 as Any } ?? NSNull(),
            "cover_url": coverUrl.map { $0 as Any } ?? NSNull(),
            "intro": intro,
            "raw": metadata.mapValues(\.value)
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, episode, intro
        case albumId = "album_id"
        case orderNo = "order_no"
        case isPaid = "is_paid"
        case isAuthorized = "is_authorized"
        case coverUrl = "cover_url"
        case metadata = "raw"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try c.decodeIfPresent(
            [String: CatalogueValue].self, forKey: .metadata
        ) ?? [:]
        try self.init(
            rawId: c.decode(String.self, forKey: .id),
            title: c.decode(String.self, forKey: .title),
            artist: c.decode(String.self, forKey: .artist),
            album: c.decode(String.self, forKey: .album),
            albumId: c.decode(String.self, forKey: .albumId),
            duration: c.decode(Double.self, forKey: .duration),
            orderNo: c.decodeIfPresent(Int.self, forKey: .orderNo),
            episode: c.decodeIfPresent(Int.self, forKey: .episode),
            isPaid: c.decodeIfPresent(Bool.self, forKey: .isPaid),
            isAuthorized: c.decodeIfPresent(Bool.self, forKey: .isAuthorized),
            coverUrl: c.decodeIfPresent(String.self, forKey: .coverUrl),
            intro: c.decode(String.self, forKey: .intro),
            raw: metadata.mapValues { Optional($0.value) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(albumId, forKey: .albumId)
        try c.encode(duration, forKey: .duration)
        try c.encode(orderNo, forKey: .orderNo)
        try c.encode(episode, forKey: .episode)
        try c.encode(isPaid, forKey: .isPaid)
        try c.encode(isAuthorized, forKey: .isAuthorized)
        try c.encode(coverUrl, forKey: .coverUrl)
        try c.encode(intro, forKey: .intro)
        try c.encode(metadata, forKey: .metadata)
    }
}

struct Album: Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let intro: String
    let coverUrl: String?
    let total: Int
    private let metadata: [String: CatalogueValue]

    var raw: [String: Any?] {
        metadata.mapValues { Optional($0.value) }
    }

    init(
        rawId: String,
        title: String = "",
        artist: String = "",
        intro: String = "",
        coverUrl: String? = nil,
        total: Int = 0,
        raw: [String: Any?] = [:]
    ) throws {
        id = try xmlyIdentifier(rawId)
        self.title = title
        self.artist = artist
        self.intro = intro
        self.coverUrl = coverUrl
        self.total = total
        metadata = try CatalogueValue.sanitized(raw)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, intro, coverUrl, total
        case metadata = "raw"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try c.decodeIfPresent(
            [String: CatalogueValue].self, forKey: .metadata
        ) ?? [:]
        try self.init(
            rawId: c.decode(String.self, forKey: .id),
            title: c.decode(String.self, forKey: .title),
            artist: c.decode(String.self, forKey: .artist),
            intro: c.decode(String.self, forKey: .intro),
            coverUrl: c.decodeIfPresent(String.self, forKey: .coverUrl),
            total: c.decode(Int.self, forKey: .total),
            raw: metadata.mapValues { Optional($0.value) }
        )
    }
}

struct AlbumPage: Sendable {
    let album: Album
    let tracks: [Track]
    let page: Int
    var pageSize: Int = ProtocolConfig.XMLY_ALBUM_PAGE_SIZE
    let total: Int
}

struct SearchPage: Sendable {
    enum Kind: String, Sendable {
        case track, album
    }

    let tracks: [Track]
    let albums: [Album]
    let page: Int
    let pageSize: Int
    let total: Int
    let kind: Kind

    init(
        tracks: [Track] = [],
        albums: [Album] = [],
        page: Int,
        pageSize: Int,
        total: Int,
        kind: Kind
    ) {
        self.tracks = tracks
        self.albums = albums
        self.page = page
        self.pageSize = pageSize
        self.total = total
        self.kind = kind
    }
}

struct Comment: Sendable {
    let id: String
    let uid: String
    let nickname: String
    let avatarUrl: String?
    let content: String
    let createdAt: String
    let likes: Int
    let replyCount: Int
    var replies: [Comment] = []

    var hasTime: Bool { !createdAt.isEmpty }

    // 默认参数与 Kotlin Comment 一致。
    init(
        id: String = "",
        uid: String = "",
        nickname: String = "",
        avatarUrl: String? = nil,
        content: String = "",
        createdAt: String = "",
        likes: Int = 0,
        replyCount: Int = 0,
        replies: [Comment] = []
    ) {
        self.id = id
        self.uid = uid
        self.nickname = nickname
        self.avatarUrl = avatarUrl
        self.content = content
        self.createdAt = createdAt
        self.likes = likes
        self.replyCount = replyCount
        self.replies = replies
    }
}

struct CommentPage: Sendable {
    let comments: [Comment]
    let page: Int
    let totalPages: Int
    let total: Int
    var hasMore: Bool { page < totalPages }
}

struct HistoryRecord: Sendable, Codable {
    let track: Track
    let positionSeconds: Double
    let updatedAt: Int64
}

struct Quota: Sendable, Codable {
    let remainingSeconds: Int
    let newDevice: Bool
    // 毫秒时间戳是存储真值（与 Kotlin Instant.ofEpochMilli/toEpochMilli
    // 一致，整数毫秒往返无损）；checkedAt 仅为 Date 视图。
    // remainingSeconds 与 Kotlin 同为 32 位 Int，范围 0...Int32.max。
    let checkedAtMillis: Int64

    var checkedAt: Date {
        Date(timeIntervalSince1970: Double(checkedAtMillis) / 1000)
    }

    init(remainingSeconds: Int, newDevice: Bool, checkedAt: Date) throws {
        let millis = checkedAt.timeIntervalSince1970 * 1000
        guard remainingSeconds >= 0,
              remainingSeconds <= Int(Int32.max),
              millis.isFinite,
              let checkedAtMillis = Int64(exactly: millis.rounded()) else {
            throw XmlyError.failure(
                code: .invalidQuota, message: "听时额度格式无效"
            )
        }
        self.remainingSeconds = remainingSeconds
        self.newDevice = newDevice
        self.checkedAtMillis = checkedAtMillis
    }

    init(remainingSeconds: Int, newDevice: Bool, checkedAtMillis: Int64) throws {
        guard remainingSeconds >= 0,
              remainingSeconds <= Int(Int32.max) else {
            throw XmlyError.failure(
                code: .invalidQuota, message: "听时额度格式无效"
            )
        }
        self.remainingSeconds = remainingSeconds
        self.newDevice = newDevice
        self.checkedAtMillis = checkedAtMillis
    }

    var stateJSON: [String: Any] {
        [
            "remainingSeconds": remainingSeconds,
            "newDevice": newDevice,
            "checkedAt": checkedAtMillis
        ]
    }

    static func fromState(_ value: Any?) -> Quota? {
        // 与 AccountSummary.balance 同义的宽容解析：org.json opt* 转换表
        //（数值字符串可解析、字符串布尔按 "true" 解析、数值布尔为 false），
        // 缺字段取 Kotlin 默认值（newDevice=false、checkedAt=0），
        // remainingSeconds < 0 或超 Int32.max 则无额度。
        guard let object = value as? [String: Any] else {
            return nil
        }
        let remaining = xmlyJsonInt(object["remainingSeconds"], default: -1)
        guard remaining >= 0, remaining <= Int(Int32.max) else { return nil }
        let newDevice = xmlyJsonBool(object["newDevice"], default: false)
        let millis = xmlyJsonLong(object["checkedAt"], default: 0)
        return try? Quota(
            remainingSeconds: remaining,
            newDevice: newDevice,
            checkedAtMillis: millis
        )
    }

    private enum CodingKeys: String, CodingKey {
        case remainingSeconds, newDevice, checkedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            remainingSeconds: c.decode(Int.self, forKey: .remainingSeconds),
            newDevice: c.decode(Bool.self, forKey: .newDevice),
            checkedAtMillis: c.decode(Int64.self, forKey: .checkedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(remainingSeconds, forKey: .remainingSeconds)
        try c.encode(newDevice, forKey: .newDevice)
        try c.encode(checkedAtMillis, forKey: .checkedAt)
    }
}

struct ResolvedAudio: Sendable, CustomStringConvertible,
                      CustomDebugStringConvertible, CustomReflectable {
    let url: String
    var headers: [String: String] = [:]
    let requiresReward: Bool
    let track: Track
    let actualQuality: String
    let accountIdentity: String

    // URL 与 headers 可能携带签名认证信息；诊断输出一律脱敏。
    var description: String { "ResolvedAudio(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": "redacted"])
    }
}

// 含凭据的服务结果不参与 Codable 持久化。
struct LoginResult: Sendable, CustomStringConvertible,
                    CustomDebugStringConvertible, CustomReflectable {
    let credentials: Credentials
    let nickname: String
    let avatarUrl: String?
    let mobile: String

    // mobile 为敏感资料；诊断输出一律脱敏（内部 Credentials 本身已脱敏）。
    var description: String { "LoginResult(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": "redacted"])
    }

    // 默认参数与 Kotlin LoginResult 一致。
    init(
        credentials: Credentials,
        nickname: String = "",
        avatarUrl: String? = nil,
        mobile: String = ""
    ) {
        self.credentials = credentials
        self.nickname = nickname
        self.avatarUrl = avatarUrl
        self.mobile = mobile
    }
}

struct SubscriptionItem: Sendable {
    let album: Album
    let latestTitle: String
    let unreadCount: Int
    let updatedAt: Int64
}

struct SubscriptionPage: Sendable {
    let items: [SubscriptionItem]
    let hasMore: Bool
}

struct FavoritePage: Sendable {
    let items: [Track]
    let hasMore: Bool
}

struct UpdateItem: Sendable {
    let track: Track
    let publishedAt: Int64
}

struct UpdatePage: Sendable {
    let items: [UpdateItem]
    let hasMore: Bool
    let nextTimeline: Int64?
}
