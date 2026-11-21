import Foundation

struct Bookmark: Sendable {
    let track: Track
    let positionMs: Int64
    let createdAt: Int64

    func toJson() -> [String: Any] {
        let metadata = track.toJson()
            .compactMapValues { $0 }
            .filter { !($0.value is NSNull) }
        return [
            "track": metadata,
            "position": positionMs,
            "createdAt": createdAt
        ]
    }

    static func fromJson(_ value: [String: Any]) -> Bookmark? {
        guard let raw = value["track"] as? [String: Any] else { return nil }

        func text(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            return B1JSON.text(value)
        }

        let original = text(raw["id"])
        let id: String
        if let colon = original.firstIndex(of: ":") {
            id = String(original[original.index(after: colon)...])
        } else {
            id = original
        }
        guard !id.isEmpty else { return nil }

        let duration: Double
        if let number = raw["duration"] as? NSNumber, !xmlyIsBoolean(number) {
            duration = number.doubleValue
        } else {
            duration = 0
        }
        let cover = raw["cover_url"] as? String

        guard let track = try? Track(
            rawId: id,
            title: text(raw["title"]),
            artist: text(raw["artist"]),
            album: text(raw["album"]),
            albumId: text(raw["album_id"]),
            duration: duration,
            coverUrl: cover?.isEmpty == false ? cover : nil
        ) else {
            return nil
        }

        return Bookmark(
            track: track,
            positionMs: xmlyJsonLong(value["position"], default: 0),
            createdAt: xmlyJsonLong(value["createdAt"], default: 0)
        )
    }
}

final class XmlyBookmarkService {
    private let repository: StateRepository
    private let accountStore: AccountStore
    private let now: () -> Int64

    init(
        repository: StateRepository,
        accountStore: AccountStore,
        now: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.repository = repository
        self.accountStore = accountStore
        self.now = now
    }

    func list() async -> [Bookmark] {
        guard let identity = await accountStore.activeAccount()?.identity else {
            return []
        }
        return await list(identity: identity)
    }

    @discardableResult
    func add(track: Track, positionMs: Int64) async throws -> [Bookmark] {
        guard let identity = await accountStore.activeAccount()?.identity else {
            return []
        }
        let bookmark = Bookmark(
            track: track,
            positionMs: max(0, positionMs),
            createdAt: now()
        )

        try await repository.transaction { document in
            // 账号已在另一个操作中切换时，不向新的活动账号写入旧请求。
            guard document.activeAccountId == identity else { return }
            var library = document.library
            var account = library[identity] as? [String: Any] ?? [:]
            let existing = account["bookmarks"] as? [Any] ?? []
            var kept = existing.compactMap { $0 as? [String: Any] }.filter {
                Bookmark.fromJson($0)?.track.id != track.id
            }
            kept.append(bookmark.toJson())
            account["bookmarks"] = kept
            library[identity] = account
            try document.setValue(library, forKey: "library")
        }
        return await list(identity: identity)
    }

    @discardableResult
    func remove(trackId: String) async throws -> [Bookmark] {
        guard let identity = await accountStore.activeAccount()?.identity else {
            return []
        }
        try await repository.transaction { document in
            guard document.activeAccountId == identity else { return }
            var library = document.library
            guard var account = library[identity] as? [String: Any],
                  let existing = account["bookmarks"] as? [Any] else {
                return
            }
            account["bookmarks"] = existing
                .compactMap { $0 as? [String: Any] }
                .filter { Bookmark.fromJson($0)?.track.id != trackId }
            library[identity] = account
            try document.setValue(library, forKey: "library")
        }
        return await list(identity: identity)
    }

    private func list(identity: String) async -> [Bookmark] {
        let document = await repository.state()
        guard document.activeAccountId == identity,
              let account = document.library[identity] as? [String: Any],
              let values = account["bookmarks"] as? [Any] else {
            return []
        }
        // 相同毫秒保留原始顺序，与 Kotlin 的稳定排序一致。
        return values.enumerated().compactMap { index, value -> (Int, Bookmark)? in
            guard let object = value as? [String: Any],
                  let bookmark = Bookmark.fromJson(object) else {
                return nil
            }
            return (index, bookmark)
        }.sorted {
            if $0.1.createdAt != $1.1.createdAt {
                return $0.1.createdAt > $1.1.createdAt
            }
            return $0.0 < $1.0
        }.map { $0.1 }
    }
}
