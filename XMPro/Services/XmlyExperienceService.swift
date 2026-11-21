import Foundation

final class XmlyExperienceService {
    private let client: XmlyClientService

    init(client: XmlyClientService) {
        self.client = client
    }

    func subscriptions(
        page: Int = 1,
        pageSize: Int = 30
    ) async throws -> SubscriptionPage {
        try requireAccount()
        try paging(page: page, size: pageSize)
        let data = try await get(
            path: "/fsubscribe-web/subscribe/comprehensive/rank/\(stamp())",
            query: ["pageId": String(page), "sign": "2", "size": String(pageSize)]
        )
        var seen: Set<String> = []
        var items: [SubscriptionItem] = []
        for row in try rows(value: data["albumResults"]).prefix(pageSize) {
            guard !text(value: row["albumId"]).isEmpty else { continue }
            guard let album = try? subscriptionAlbum(row: row) else { continue }
            guard seen.insert(album.id).inserted else {
                throw repeated("订阅列表重复，请刷新后重试")
            }
            let unread = integer(value: row["unreadNum"]) ?? 0
            let updatedAt = (try? time(value: row["lastUpdateAt"] ?? 0)) ?? 0
            items.append(SubscriptionItem(
                album: album,
                latestTitle: text(value: row["trackTitle"]),
                unreadCount: unread,
                updatedAt: updatedAt
            ))
        }
        let hasMore = B1JSON.boolean(data["hasMore"]) ?? (items.count >= pageSize)
        guard !hasMore || !items.isEmpty else { throw invalid }
        return SubscriptionPage(items: items, hasMore: hasMore)
    }

    func favorites(
        page: Int = 1,
        pageSize: Int = 30
    ) async throws -> FavoritePage {
        try requireAccount()
        try paging(page: page, size: pageSize)
        let data = try await get(
            path: "/lite-mobile/like/v1/user-likes",
            query: ["pageId": String(page), "pageSize": String(pageSize)]
        )
        let maxPage = integer(value: data["maxPageId"]) ?? 0

        var seen: Set<String> = []
        var items: [Track] = []
        for row in try rows(value: data["dataList"]).prefix(pageSize) {
            guard integer(value: row["resourceType"]) == 1 else { continue }
            guard !text(value: row["trackId"]).isEmpty || !text(value: row["id"]).isEmpty else { continue }
            guard let item = try? track(row: row), !item.albumKey.isEmpty else { continue }
            guard seen.insert(item.id).inserted else {
                throw repeated("收藏列表重复，请刷新后重试")
            }
            items.append(item)
        }
        let hasMore = page < maxPage
        return FavoritePage(items: items, hasMore: hasMore)
    }

    func updates(
        before: Int64? = nil,
        pageSize: Int = 30
    ) async throws -> UpdatePage {
        try requireAccount()
        try paging(page: 1, size: pageSize)
        if let before, !(1...2_115_354_119_000).contains(before) {
            throw invalid
        }
        var query = ["sign": "2", "size": String(pageSize)]
        if let before { query["timeline"] = String(before) }
        let data = try await get(
            path: "/track-feed/v1/track-feed/dynamic/ts-\(stamp())",
            query: query
        )
        var seen: Set<String> = []
        var cursor: Int64?
        var items: [UpdateItem] = []
        for row in try rows(value: data["trackResults"]).prefix(pageSize) {
            guard let item = try? track(row: row) else { continue }
            guard seen.insert(item.id).inserted else {
                throw repeated("更新列表重复，请刷新后重试")
            }
            guard let timeline = try? time(value: row["timeline"]), timeline > 0 else { continue }
            if let cursor, timeline > cursor { continue }
            cursor = timeline
            let published = (try? time(value: row["createdAt"] ?? timeline)) ?? timeline
            items.append(UpdateItem(
                track: item,
                publishedAt: published
            ))
        }
        let hasMore = try more(data: data)
        if let before, let cursor, cursor >= before {
            throw repeated("暂时无法读取更早的更新，已保留当前列表")
        }
        return UpdatePage(
            items: items,
            hasMore: hasMore && (cursor ?? 0) > 0,
            nextTimeline: cursor
        )
    }

    /// 订阅或取消订阅专辑（对齐上游 aef0547：mobile 端返回 ret=791，统一改用 Web 端接口，接受 ret=200/0）。
    func setSubscribed(albumId: String, subscribed: Bool) async throws {
        try requireAccount()
        let id = try xmlyIdentifier(albumId)
        let payload = try await client.request(
            method: "POST",
            origin: XmlyOrigin.www.rawValue,
            path: subscribed
                ? "/revision/subscription/setSubscriptionAlbum"
                : "/revision/subscription/cancelSubscriptionAlbum",
            form: ["albumId": id],
            readOnly: false
        )
        let ret = integer(value: payload["ret"])
        guard ret == 200 || ret == 0 else { throw invalid }
    }

    func setFavorite(track: Track, favorite: Bool) async throws {
        try requireAccount()
        let id = try xmlyIdentifier(track.id)
        var album = track.albumKey
        if album.isEmpty {
            album = try await client.track(number: id).albumKey
        }
        guard !album.isEmpty else {
            throw B1JSON.error(.missingAlbum, definitive: true)
        }
        let payload = try await client.request(
            method: "POST",
            origin: XmlyOrigin.mobile.rawValue,
            path: favorite ? "/lite-mobile/like/v1/like" : "/lite-mobile/like/v1/dislike",
            form: ["resourceId": id, "albumId": album, "resourceType": "1"],
            readOnly: false
        )
        guard integer(value: payload["ret"]) == 0 else { throw invalid }
    }

    func profile() async throws -> UserProfile {
        try requireAccount()
        guard let uid = try client.context()["uid"], !uid.isEmpty else {
            throw invalid
        }
        let payload = try await profilePayload(uid: uid)
        let counts = try? await socialCounts(uid: uid)
        let nickname = findString(
            root: payload, keys: ["nickname", "userName", "name", "nickName"]
        ) ?? ""
        let avatar = findString(
            root: payload, keys: ["avatar", "avatarUrl", "logoPic", "smallLogo", "cover"]
        )
        let mobile = findString(
            root: payload, keys: ["mobile", "phone", "mobilePhone"]
        ) ?? ""
        guard !nickname.isEmpty || avatar != nil || !mobile.isEmpty else {
            throw profileUnavailable
        }

        // 既有 UserProfile 不含 mobile；它仅参与资料可用性判断。
        return UserProfile(
            uid: uid,
            nickname: nickname,
            avatarUrl: cdnUrl(avatar),
            intro: findString(
                root: payload, keys: ["personalSignature", "intro", "description"]
            ) ?? "",
            followers: counts?.followers,
            following: counts?.following,
            subscriptions: counts?.subscriptions
        )
    }

    func userPage(uid: String) async throws -> UserPage {
        let payload = try await userPayload(uid: uid)
        guard let data = payload["data"] as? [String: Any] else { throw invalid }
        let pub = data["pubPageInfo"] as? [String: Any] ?? [:]
        let list = pub["pubInfoList"] as? [Any] ?? []
        var nickname = ""
        var avatar: String?
        var intro = ""
        var albums: [Album] = []

        for value in list {
            guard let item = value as? [String: Any] else { continue }
            let id = xmlyJsonInt(item["id"], default: 0)
            guard id > 0 else { continue }
            let name = text(value: item["anchorNickName"])
            let cover = cdnUrl(item["coverPath"] as? String)
            let subtitle = text(value: item["subTitle"])
            if nickname.isEmpty { nickname = name }
            if avatar == nil { avatar = cover }
            let total = xmlyJsonInt(item["trackCount"], default: 0)
            let title = text(value: item["title"])
            let raw: [String: Any] = [
                "id": id,
                "title": title,
                "albumTitle": title,
                "intro": subtitle,
                "total": total,
                "isFinished": B1JSON.boolean(item["isFinished"]) ?? false,
                "isPaid": B1JSON.boolean(item["isPaid"]) ?? false
            ]
            albums.append(try Album(
                rawId: String(id),
                title: title,
                artist: name,
                intro: subtitle,
                coverUrl: cover,
                total: max(0, total),
                raw: publicRaw(raw).mapValues { Optional($0) }
            ))
        }

        if nickname.isEmpty || avatar == nil || intro.isEmpty,
           let profile = try? await profileOf(uid: uid) {
            if nickname.isEmpty { nickname = profile.nickname }
            if avatar == nil { avatar = profile.avatarUrl }
            if intro.isEmpty { intro = profile.intro }
        }

        func count(_ key: String) -> Int {
            let page = data[key] as? [String: Any] ?? [:]
            return xmlyJsonInt(page["totalCount"], default: 0)
        }

        return UserPage(
            uid: uid,
            nickname: nickname,
            avatarUrl: avatar,
            intro: intro,
            followers: count("fansPageInfo"),
            following: count("followingPageInfo"),
            albums: albums,
            totalAlbums: xmlyJsonInt(pub["totalCount"], default: 0)
        )
    }

    func following(uid: String) async throws -> [SocialUser] {
        try await socialList(
            uid: uid, pageKey: "followingPageInfo", listKey: "followInfoList"
        )
    }

    func fans(uid: String) async throws -> [SocialUser] {
        try await socialList(
            uid: uid, pageKey: "fansPageInfo", listKey: "fansInfoList"
        )
    }

    func socialCounts(uid: String) async throws -> SocialCounts {
        let payload = try await userPayload(uid: uid)
        guard let data = payload["data"] as? [String: Any] else { throw invalid }

        func count(_ key: String) -> Int {
            let page = data[key] as? [String: Any] ?? [:]
            return xmlyJsonInt(page["totalCount"], default: 0)
        }

        return SocialCounts(
            following: count("followingPageInfo"),
            followers: count("fansPageInfo"),
            subscriptions: count("subscriptionPageInfo"),
            albums: count("pubPageInfo"),
            tracks: count("trackPageInfo")
        )
    }

    private func socialList(
        uid: String, pageKey: String, listKey: String
    ) async throws -> [SocialUser] {
        let payload = try await userPayload(uid: uid)
        let data = payload["data"] as? [String: Any] ?? [:]
        let page = data[pageKey] as? [String: Any] ?? [:]
        let list = page[listKey] as? [Any] ?? []
        return list.compactMap { value in
            guard let item = value as? [String: Any] else { return nil }
            let id = xmlyJsonInt(item["uid"], default: 0)
            guard id > 0 else { return nil }
            let primaryName = text(value: item["anchorNickName"])
            return SocialUser(
                uid: String(id),
                nickname: primaryName.isEmpty
                    ? text(value: item["nickName"]) : primaryName,
                avatarUrl: cdnUrl(item["coverPath"] as? String),
                followers: xmlyJsonInt(item["followerCount"], default: 0),
                albums: xmlyJsonInt(item["albumCount"], default: 0),
                intro: text(value: item["description"])
            )
        }
    }

    private func userPayload(
        uid: String, includeProfile: Bool = false
    ) async throws -> [String: Any] {
        var query = ["uid": uid]
        if includeProfile { query["includeProfile"] = "1" }
        return try await client.request(
            method: "GET",
            origin: XmlyOrigin.search.rawValue,
            path: "/revision/user",
            query: query,
            account: client.hasAccount
        )
    }

    private func profileOf(uid: String) async throws -> UserProfile {
        let payload = try await client.requestOrdered(
            method: "GET",
            origin: XmlyOrigin.search.rawValue,
            path: "/revision/user",
            query: ["uid": uid, "includeProfile": "1"],
            account: client.hasAccount
        )
        guard let data = payload["data"], case .object = data else {
            throw invalid
        }
        return UserProfile(
            uid: uid,
            nickname: findString(
                root: data, keys: ["anchorNickName", "nickname", "userName"]
            ) ?? "",
            avatarUrl: cdnUrl(findString(
                root: data, keys: ["coverPath", "avatar", "cover"]
            )),
            intro: findString(root: data, keys: ["description", "intro"]) ?? ""
        )
    }

    private func profilePayload(uid: String) async throws -> XmlyJSONValue {
        var lastError: Error?
        let attempts: [(XmlyOrigin, String, [String: String])] = [
            (.search, "/revision/my/getCurrentUserInfo", [:]),
            (.mobile, "/mobile-user/user/detail", ["uid": uid, "device": "android"])
        ]
        for (origin, path, query) in attempts {
            do {
                let payload = try await client.requestOrdered(
                    method: "GET",
                    origin: origin.rawValue,
                    path: path,
                    query: query
                )
                if let data = payload["data"], case .object = data {
                    return payload
                }
                if payload["uid"] != nil {
                    return payload
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw profileUnavailable
    }

    // internal 供 @testable 直接验证保序 BFS；不暴露到应用外部。
    func findString(root: XmlyJSONValue, keys: Set<String>) -> String? {
        find(root: root, keys: keys) { value in
            guard case let .string(string) = value,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return string
        }
    }

    func findCount(root: XmlyJSONValue, keys: Set<String>) -> Int? {
        find(root: root, keys: keys) { value in
            guard let integer = xmlyOptInt(value), integer >= 0 else {
                return nil
            }
            return integer
        }
    }

    private func find<Value>(
        root: XmlyJSONValue,
        keys: Set<String>,
        parse: (XmlyJSONValue) -> Value?
    ) -> Value? {
        var queue: [XmlyJSONValue] = [root]
        var index = 0

        func append(_ value: XmlyJSONValue) {
            guard queue.count < 3_000 else { return }
            switch value {
            case .object, .array:
                queue.append(value)
            default:
                break
            }
        }

        while index < queue.count && index < 3_000 {
            let node = queue[index]
            index += 1
            switch node {
            case let .object(members):
                for (key, value) in members where keys.contains(key) {
                    if let result = parse(value) { return result }
                }
                for (_, child) in members { append(child) }
            case let .array(array):
                for child in array { append(child) }
            default:
                break
            }
        }
        return nil
    }

    private var profileUnavailable: XmlyError {
        .failure(
            code: .profileUnavailable,
            message: "账号资料不可用",
            definitive: true
        )
    }

    private var invalid: XmlyError {
        B1JSON.error(.invalidHome, definitive: true)
    }

    private func repeated(_ message: String) -> XmlyError {
        .failure(code: .repeatedPage, message: message)
    }

    private func requireAccount() throws {
        guard client.hasAccount else {
            throw XmlyError.failure(
                code: .loginRequired,
                message: "登录后使用订阅、收藏和更新",
                definitive: true
            )
        }
    }

    private func get(
        path: String,
        query: [String: String]
    ) async throws -> [String: Any] {
        let payload = try await client.request(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: path,
            query: query,
            account: client.hasAccount
        )
        guard let data = payload["data"] as? [String: Any] else { throw invalid }
        return data
    }

    private func paging(page: Int, size: Int) throws {
        guard (1...10_000).contains(page), (1...50).contains(size) else {
            throw B1JSON.error(.invalidPage, definitive: true)
        }
    }

    private func rows(value: Any?) throws -> [[String: Any]] {
        let array: [Any]
        if let values = value as? [Any] {
            array = values
        } else if let object = value as? [String: Any],
                  let values = object["list"] as? [Any] {
            array = values
        } else {
            return []
        }
        guard array.count <= 500 else { throw invalid }
        return array.compactMap { $0 as? [String: Any] }
    }

    private func integer(value: Any?) -> Int? {
        let string = text(value: value)
        guard ProtocolBytes.fullMatch(#"^[+-]?[0-9]+$"#, string),
              let number = Int64(string),
              (0...Int64(Int32.max)).contains(number) else {
            return nil
        }
        return Int(number)
    }

    private func text(value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if value is String || value is NSNumber { return B1JSON.text(value) }
        return (try? B1JSON.encode(value)) ?? "[invalid]"
    }

    private func time(value: Any?) throws -> Int64 {
        let number: Int64
        if let raw = value as? NSNumber, !xmlyIsBoolean(raw) {
            number = xmlyJsonLong(raw, default: -1)
        } else if let raw = value as? String,
                  ProtocolBytes.fullMatch(#"^[+-]?[0-9]+$"#, raw),
                  let parsed = Int64(raw) {
            number = parsed
        } else {
            throw invalid
        }
        guard (0...2_115_354_119_000).contains(number) else { throw invalid }
        return number
    }

    private func more(data: [String: Any]) throws -> Bool {
        guard let result = B1JSON.boolean(data["hasMore"]) else { throw invalid }
        return result
    }

    private func stamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private func album(row: [String: Any]) throws -> Album {
        try parseAlbum(row: row, subscription: false)
    }

    private func subscriptionAlbum(row: [String: Any]) throws -> Album {
        try parseAlbum(row: row, subscription: true)
    }

    private func parseAlbum(
        row: [String: Any],
        subscription: Bool
    ) throws -> Album {
        let id = text(value: row["albumId"])
        guard !id.isEmpty else { throw invalid }
        var plain: [String: Any] = [:]
        for key in [
            "albumTitle", "albumIntro", "nickname",
            "coverLarge", "coverMiddle", "coverSmall"
        ] {
            plain[key] = text(value: row[key])
        }
        if subscription { plain["cover_url"] = text(value: row["albumCover"]) }
        return try Album(
            rawId: xmlyIdentifier(id),
            title: text(value: plain["albumTitle"]),
            artist: text(value: plain["nickname"]),
            intro: text(value: plain["albumIntro"]),
            coverUrl: coverUrl(plain),
            total: integer(value: row["trackCount"]) ?? 0,
            raw: publicRaw(plain).mapValues { Optional($0) }
        )
    }

    private func track(row: [String: Any]) throws -> Track {
        let primary = text(value: row["trackId"])
        let id = primary.isEmpty ? text(value: row["id"]) : primary
        guard !id.isEmpty else { throw invalid }
        let primaryAlbum = text(value: row["albumId"])
        let albumId = primaryAlbum.isEmpty
            ? text(value: row["album_id"]) : primaryAlbum
        var plain: [String: Any] = [
            "trackId": id,
            "albumId": albumId,
            "cover_url": text(value: row["cover"])
        ]
        for key in [
            "title", "nickname", "albumTitle",
            "coverLarge", "coverMiddle", "coverSmall"
        ] {
            plain[key] = text(value: row[key])
        }

        let duration: Double
        if let number = row["duration"] as? NSNumber, !xmlyIsBoolean(number) {
            duration = number.doubleValue
        } else if let string = row["duration"] as? String {
            duration = B1JSON.jvmDouble(string) ?? 0
        } else {
            duration = 0
        }

        return try Track(
            rawId: id,
            title: text(value: plain["title"]),
            artist: text(value: plain["nickname"]),
            album: text(value: plain["albumTitle"]),
            albumId: albumId,
            duration: duration,
            isPaid: B1JSON.boolean(row["isPaid"]) ?? B1JSON.boolean(row["paid"]),
            isAuthorized: B1JSON.boolean(row["isAuthorized"])
                ?? B1JSON.boolean(row["authorized"]),
            coverUrl: coverUrl(plain),
            raw: publicRaw(plain).mapValues { Optional($0) }
        )
    }
}
