// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct ChannelItem: Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var enabled: Bool
    var order: Int

    func toJson() -> [String: Any] {
        [
            "id": id,
            "title": title,
            "enabled": enabled,
            "order": order
        ]
    }

    static func fromJson(_ json: [String: Any], fallbackOrder: Int) -> ChannelItem? {
        guard let rawId = json["id"] ?? json["pageId"] ?? json["channelId"],
              !(rawId is NSNull) else {
            return nil
        }
        let id = B1JSON.text(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        let titleRaw = json["title"] ?? json["name"] ?? json["pageName"]
        let title = (titleRaw.map { B1JSON.text($0) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let enabled = B1JSON.boolean(json["enabled"]) ?? true
        let order = xmlyOptInt(json["order"]) ?? fallbackOrder
        return ChannelItem(
            id: id,
            title: title.isEmpty ? "频道 \(id)" : title,
            enabled: enabled,
            order: max(0, order)
        )
    }
}

struct HomeSubTab: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let isDefault: Bool
}

struct HomeAlbumCard: Sendable, Identifiable {
    var id: String { album.id }
    let album: Album
    let score: String?
    let playCount: Int64?
    let subscribeCount: Int64?
    let rank: Int?
}

struct HomeRankingList: Sendable, Identifiable {
    let id: String
    let title: String
    let cards: [HomeAlbumCard]
}

struct HomeModuleItem: Sendable, Identifiable {
    let id: String
    let title: String
    let moduleType: String
    let albumCount: Int
    let albums: [Album]
    let cards: [HomeAlbumCard]
    let subTabs: [HomeSubTab]
    let rankings: [HomeRankingList]

    init(
        id: String,
        title: String,
        moduleType: String,
        albumCount: Int,
        albums: [Album] = [],
        cards: [HomeAlbumCard] = [],
        subTabs: [HomeSubTab] = [],
        rankings: [HomeRankingList] = []
    ) {
        self.id = id
        self.title = title
        self.moduleType = moduleType
        self.albumCount = albumCount
        self.albums = albums
        self.cards = cards
        self.subTabs = subTabs
        self.rankings = rankings
    }
}

final class XmlyChannelService {
    static let defaultChannels: [ChannelItem] = [
        ChannelItem(id: "2", title: "推荐", enabled: true, order: 0),
        ChannelItem(id: "22", title: "小说", enabled: true, order: 1),
        ChannelItem(id: "4", title: "相声评书", enabled: true, order: 2),
        ChannelItem(id: "6", title: "儿童", enabled: true, order: 3),
        ChannelItem(id: "7", title: "历史", enabled: true, order: 4),
        ChannelItem(id: "19", title: "听音乐", enabled: true, order: 5)
    ]

    private let client: XmlyClientService
    private let repository: StateRepository?
    private let clock: ServerClock

    init(
        client: XmlyClientService,
        repository: StateRepository?,
        clock: ServerClock = .shared
    ) {
        self.client = client
        self.repository = repository
        self.clock = clock
    }

    func loadSavedChannels() async -> [ChannelItem] {
        guard let repository else { return Self.defaultChannels }
        let document = await repository.state()
        guard let rawList = document.settings["channels"] as? [Any], !rawList.isEmpty else {
            return Self.defaultChannels
        }
        var seen: Set<String> = []
        let parsed = rawList.enumerated().compactMap { index, value -> (Int, ChannelItem)? in
            guard let object = value as? [String: Any],
                  let item = ChannelItem.fromJson(object, fallbackOrder: index),
                  seen.insert(item.id).inserted else {
                return nil
            }
            return (index, item)
        }.sorted {
            if $0.1.order != $1.1.order { return $0.1.order < $1.1.order }
            return $0.0 < $1.0
        }.enumerated().map { idx, pair -> ChannelItem in
            var normalized = pair.1
            normalized.order = idx
            return normalized
        }
        return parsed.isEmpty ? Self.defaultChannels : parsed
    }

    @discardableResult
    func saveChannels(_ channels: [ChannelItem]) async throws -> [ChannelItem] {
        var seen: Set<String> = []
        let normalized = channels.compactMap { item -> ChannelItem? in
            guard !item.id.isEmpty, seen.insert(item.id).inserted else { return nil }
            return item
        }.enumerated().map { index, item -> ChannelItem in
            ChannelItem(
                id: item.id,
                title: item.title,
                enabled: item.enabled,
                order: index
            )
        }

        guard let repository else { return normalized }
        try await repository.transaction { document in
            var settings = document.settings
            settings["channels"] = normalized.map { $0.toJson() }
            try document.setSettings(settings)
        }
        return normalized
    }

    func setEnabled(id: String, enabled: Bool) async throws -> [ChannelItem] {
        var current = await loadSavedChannels()
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            return current
        }
        current[index].enabled = enabled
        return try await saveChannels(current)
    }

    func move(from sourceIndex: Int, to destinationIndex: Int) async throws -> [ChannelItem] {
        var current = await loadSavedChannels()
        guard current.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= current.count else {
            return current
        }
        let item = current.remove(at: sourceIndex)
        let target = min(destinationIndex, current.count)
        current.insert(item, at: target)
        return try await saveChannels(current)
    }

    func syncRemoteChannels() async throws -> [ChannelItem] {
        let ts = clock.now()
        let payload = try await client.request(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/lite-mobile/index/v1/subPages/\(ts)",
            account: client.hasAccount
        )
        let remote = parseRemoteChannels(from: payload)
        guard !remote.isEmpty else {
            return await loadSavedChannels()
        }

        let local = await loadSavedChannels()
        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        var merged: [ChannelItem] = []
        var usedIds: Set<String> = []

        for existing in local {
            if let fresh = remoteById[existing.id] {
                merged.append(ChannelItem(
                    id: existing.id,
                    title: fresh.title,
                    enabled: existing.enabled,
                    order: merged.count
                ))
                usedIds.insert(existing.id)
            }
        }
        for fresh in remote where !usedIds.contains(fresh.id) {
            merged.append(ChannelItem(
                id: fresh.id,
                title: fresh.title,
                enabled: fresh.enabled,
                order: merged.count
            ))
            usedIds.insert(fresh.id)
        }

        return try await saveChannels(merged)
    }

    /// 查询首页模块（含排行榜 rankingLists、推荐流 feedStream、内容池 contentPool 与二级 pageTab）。
    func fetchModules(
        channelId: String? = nil,
        tabId: String? = nil
    ) async throws -> [HomeModuleItem] {
        let ts = clock.now()
        var query: [String: String] = [:]
        if let channelId, !channelId.isEmpty {
            query["pageId"] = channelId
        }
        if let tabId, !tabId.isEmpty {
            query["tabId"] = tabId
        }
        let payload = try await client.request(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/lite-mobile/index/v1/modules/\(ts)",
            query: query,
            account: client.hasAccount
        )
        let data = payload["data"] as? [String: Any] ?? payload
        let rawList: [Any]
        if let modulesObj = data["modules"] as? [String: Any],
           let nested = modulesObj["list"] as? [Any] {
            rawList = nested
        } else {
            rawList = (data["modules"] as? [Any])
                ?? (data["moduleList"] as? [Any])
                ?? (data["list"] as? [Any])
                ?? []
        }
        return rawList.enumerated().compactMap { index, value in
            guard let object = value as? [String: Any] else { return nil }
            let idRaw = object["moduleId"] ?? object["id"] ?? index
            let id = B1JSON.text(idRaw)
            let title = (object["title"] as? String)
                ?? (object["moduleName"] as? String)
                ?? "模块 \(index + 1)"
            let moduleType: String
            if let typeText = object["moduleCode"] as? String, !typeText.isEmpty {
                moduleType = typeText
            } else if let rawType = object["moduleType"] ?? object["type"] {
                moduleType = B1JSON.text(rawType)
            } else {
                moduleType = "unknown"
            }
            let items = (object["list"] as? [Any])
                ?? (object["items"] as? [Any])
                ?? (object["albums"] as? [Any])
                ?? []
            let subTabs = parseSubTabs(from: items)
            let rankings = moduleType == "rankingLists" ? parseRankings(from: items) : []
            let cards = (rankings.isEmpty && subTabs.isEmpty) ? parseModuleCards(from: items, ranked: false) : []
            let albums = cards.map(\.album) + rankings.flatMap { $0.cards.map(\.album) }
            return HomeModuleItem(
                id: id,
                title: title,
                moduleType: moduleType,
                albumCount: max(items.count, albums.count),
                albums: albums,
                cards: cards,
                subTabs: subTabs,
                rankings: rankings
            )
        }
    }

    private func parseSubTabs(from items: [Any]) -> [HomeSubTab] {
        var tabs: [HomeSubTab] = []
        var seen: Set<String> = []
        for entry in items {
            guard let obj = entry as? [String: Any],
                  let rawTabId = obj["tabId"], !(rawTabId is NSNull) else { continue }
            let idText = B1JSON.text(rawTabId).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !idText.isEmpty, seen.insert(idText).inserted else { continue }
            let title = (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isDefault = B1JSON.boolean(obj["isDefault"]) ?? false
            tabs.append(HomeSubTab(
                id: idText,
                title: title.isEmpty ? "分类 \(idText)" : title,
                isDefault: isDefault
            ))
        }
        return tabs
    }

    private func parseRankings(from items: [Any]) -> [HomeRankingList] {
        var lists: [HomeRankingList] = []
        for (idx, entry) in items.enumerated() {
            guard let obj = entry as? [String: Any] else { continue }
            let listItems = (obj["list"] as? [Any]) ?? (obj["albums"] as? [Any]) ?? []
            let cards = parseModuleCards(from: listItems, ranked: true)
            guard !cards.isEmpty else { continue }
            let idText = B1JSON.text(obj["rankingListId"] ?? idx)
            let name = (obj["rankingListName"] as? String)
                ?? (obj["title"] as? String)
                ?? "热播榜"
            lists.append(HomeRankingList(id: idText, title: name, cards: cards))
        }
        return lists
    }

    private func parseModuleCards(from items: [Any], ranked: Bool) -> [HomeAlbumCard] {
        var result: [HomeAlbumCard] = []
        var seen: Set<String> = []
        for entry in items {
            guard let wrapper = entry as? [String: Any] else { continue }
            let raw = (wrapper["item"] as? [String: Any])
                ?? (wrapper["albumInfo"] as? [String: Any])
                ?? wrapper
            // 仅解析真正的专辑条目：优先使用显式 albumId；
            // 避免把分类 Tab / 专题 / 广告等非专辑条目的 id 误当作 albumId（会导致无封面且点进后被接口拒绝）。
            let explicitAlbumId = raw["albumId"] ?? wrapper["albumId"]
            let rawId: Any
            if let explicitAlbumId, !(explicitAlbumId is NSNull) {
                rawId = explicitAlbumId
            } else {
                let itemType = ((wrapper["itemType"] ?? raw["itemType"] ?? raw["type"]) as? String)?.lowercased() ?? ""
                let looksLikeAlbum = itemType == "album"
                    || raw["albumTitle"] != nil
                    || raw["tracks"] != nil
                    || raw["trackCount"] != nil
                    || raw["tracksCount"] != nil
                guard looksLikeAlbum, let fallbackId = raw["id"], !(fallbackId is NSNull) else {
                    continue
                }
                rawId = fallbackId
            }
            let idText = B1JSON.text(rawId).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !idText.isEmpty, idText != "0", seen.insert(idText).inserted else { continue }
            let title = [raw["albumTitle"], raw["title"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }
            let artist = [raw["nickname"], raw["anchorNickName"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let intro = [raw["albumIntro"], raw["customTitle"], raw["intro"]]
                .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            let rawCover = [
                raw["coverLarge"],
                raw["coverOrigin"],
                raw["coverMiddle"],
                raw["coverSmall"],
                raw["coverPath"],
                raw["albumCoverPath"],
                raw["coverUrl"],
                raw["cover"],
                raw["pic"]
            ]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            let cover = normalizeHTTPS(rawCover)
            let total = max(
                0,
                xmlyOptInt(raw["tracks"] ?? raw["trackCount"] ?? raw["tracksCount"] ?? raw["total"]) ?? 0
            )
            let rawScore = raw["albumScore"] ?? raw["score"]
            let scoreText: String? = {
                guard let rawScore, !(rawScore is NSNull) else { return nil }
                let text = B1JSON.text(rawScore).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "0", text != "0.0" else { return nil }
                return text
            }()
            let playRaw = xmlyJsonLong(raw["playCount"] ?? raw["playsCounts"] ?? raw["play"], default: 0)
            let subRaw = xmlyJsonLong(raw["subscribeCount"] ?? raw["subCount"], default: 0)

            if let album = try? Album(
                rawId: idText,
                title: title,
                artist: artist,
                intro: intro,
                coverUrl: cover,
                total: total
            ) {
                result.append(HomeAlbumCard(
                    album: album,
                    score: scoreText,
                    playCount: playRaw > 0 ? playRaw : nil,
                    subscribeCount: subRaw > 0 ? subRaw : nil,
                    rank: ranked ? (result.count + 1) : nil
                ))
            }
        }
        return result
    }

    private func normalizeHTTPS(_ url: String?) -> String? {
        guard let url else { return nil }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if trimmed.hasPrefix("http://") {
            return "https://" + String(trimmed.dropFirst(7))
        }
        return trimmed
    }

    private func parseRemoteChannels(from payload: [String: Any]) -> [ChannelItem] {
        let data = payload["data"] as? [String: Any] ?? payload
        let rawList = (data["subPages"] as? [Any])
            ?? (data["pages"] as? [Any])
            ?? (data["list"] as? [Any])
            ?? (payload["data"] as? [Any])
            ?? []
        var seen: Set<String> = []
        return rawList.enumerated().compactMap { index, value in
            guard let object = value as? [String: Any],
                  let item = ChannelItem.fromJson(object, fallbackOrder: index),
                  seen.insert(item.id).inserted else {
                return nil
            }
            return item
        }
    }
}
