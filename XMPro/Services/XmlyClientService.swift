import Foundation

// 实例绑定不可变账号上下文；缓存私有，M2 写入门闩按账号共享。
final class XmlyClientService {
    let identity: String

    private let http: any HTTPTransport
    private let accountContext: AccountContext?
    private let clock: ServerClock
    private let cacheLock = NSLock()
    private var albums: [String: Album] = [:]
    private var albumKeys: [String] = []
    private var metadata: [String: Track] = [:]
    private var metadataKeys: [String] = []
    private let trackWrites: XmlyTrackWriteGate

    init(
        http: any HTTPTransport,
        accountContext: AccountContext?,
        clock: ServerClock = .shared
    ) {
        self.http = http
        self.accountContext = accountContext
        self.clock = clock
        let identity = accountContext?.identity ?? "anonymous"
        self.identity = identity
        // M2：Kotlin 没有门闩；Swift 加严为同账号、同声音跨实例互斥。
        trackWrites = XmlyTrackWriteGate.shared(for: identity)
    }

    convenience init(http: any HTTPTransport, accountContext: AccountContext?) {
        self.init(http: http, accountContext: accountContext, clock: .shared)
    }

    func request(
        method: String,
        origin: String,
        path: String,
        query: [String: String] = [:],
        form: [String: String]? = nil,
        json: [String: Any]? = nil,
        account: Bool = true,
        readOnly: Bool = true,
        signed: Bool = false,
        headers: [String: String] = [:]
    ) async throws -> [String: Any] {
        let bound = account ? try credentials() : nil
        let merged = ProtocolConfig.originHeaders(origin: origin)
            .merging(headers) { _, supplied in supplied }
        let limit: Int? = origin == XmlyOrigin.collector.rawValue
            ? 8 * 1024 * 1024 : nil

        if method == "GET" {
            return try await http.get(
                origin: origin, path: path, query: query,
                credentials: bound, signed: signed, readOnly: readOnly,
                headers: merged, responseLimit: limit
            )
        }
        if let form {
            // Swift 协议显式传 signed；Kotlin 的 form 分支不启用签名。
            return try await http.postForm(
                origin: origin, path: path, query: query, form: form,
                credentials: bound, signed: false, readOnly: readOnly,
                headers: merged, responseLimit: limit
            )
        }
        // Minor：接受通用 helper 转发 signed 的差异。Kotlin 的
        // trackInfoMap 直接调用带签名的 postJson，实际授权请求行为一致。
        return try await http.postJson(
            origin: origin, path: path, query: query, body: json ?? [:],
            credentials: bound, signed: signed, readOnly: readOnly,
            headers: merged, responseLimit: limit
        )
    }

    func requestOrdered(
        method: String,
        origin: String,
        path: String,
        query: [String: String] = [:],
        account: Bool = true,
        readOnly: Bool = true,
        signed: Bool = false,
        headers: [String: String] = [:]
    ) async throws -> XmlyJSONValue {
        let bound = account ? try credentials() : nil
        let merged = ProtocolConfig.originHeaders(origin: origin)
            .merging(headers) { _, supplied in supplied }
        let limit: Int? = origin == XmlyOrigin.collector.rawValue
            ? 8 * 1024 * 1024 : nil

        guard method == "GET" else {
            throw XmlyError.failure(
                code: .protocolError, message: "保序请求仅支持 GET"
            )
        }
        let data = try await http.getData(
            origin: origin, path: path, query: query,
            credentials: bound, signed: signed, readOnly: readOnly,
            headers: merged, responseLimit: limit
        )
        let payload = try xmlyParseOrderedJSON(data)
        guard case .object = payload else {
            throw XmlyError.failure(
                code: .invalidJSON, message: "接口返回无效 JSON"
            )
        }
        if let timestamp = payload["timestamp"] {
            switch timestamp {
            case let .integer(value):
                clock.observePayload(timestamp: NSNumber(value: value))
            case let .number(value):
                clock.observePayload(timestamp: NSNumber(value: value))
            case let .string(value):
                clock.observePayload(timestamp: value)
            default:
                break
            }
        }
        return payload
    }

    func context() throws -> [String: String] {
        ProtocolConfig.liteContext(for: try credentials())
    }

    func mainAppCookie() -> String? {
        guard let credentials = try? credentials() else { return nil }
        // B1：对应 Kotlin mainAppCookie，使用当前账号完整 uid&token。
        // ProtocolConfig 的匿名设备 Cookie 继续供登录流程使用。
        return "1&_token=\(credentials.token); "
            + "1&_device=android&\(credentials.deviceId)&9.5.1;"
            + "channel=and-d10; impl=com.ximalaya.ting.android; appid=1463"
    }

    func search(
        query: String,
        kind: String = "track",
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> SearchPage {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, query.utf16.count <= 200,
              let parsedKind = SearchPage.Kind(rawValue: kind) else {
            throw B1JSON.error(.invalidSearch, definitive: true)
        }
        try paging(page: page, pageSize: pageSize)
        let payload = try await request(
            method: "GET", origin: XmlyOrigin.search.rawValue,
            path: "/revision/search",
            query: [
                "kw": keyword, "core": kind, "page": String(page),
                "rows": String(pageSize), "device": "iPhone",
                "condition": "relation", "spellchecker": "true"
            ],
            account: false
        )
        guard let data = payload["data"] as? [String: Any],
              let result = data["result"] as? [String: Any],
              let response = result["response"] as? [String: Any],
              let docs = response["docs"] as? [Any] else {
            throw B1JSON.error(.invalidCatalogue)
        }
        var tracks: [Track] = []
        var found: [Album] = []
        for value in docs.prefix(pageSize) {
            guard let raw = value as? [String: Any] else { continue }
            if parsedKind == .album {
                guard let rawID = B1JSON.first(raw, ["albumId", "id"]) else {
                    continue
                }
                found.append(try albumFromApi(
                    raw, id: xmlyIdentifier(B1JSON.text(rawID))
                ))
            } else if let track = try trackFromApi(raw) {
                tracks.append(track)
            }
        }
        return SearchPage(
            tracks: tracks, albums: found, page: page, pageSize: pageSize,
            total: xmlyJsonInt(response["numFound"], default: docs.count),
            kind: parsedKind
        )
    }

    func album(
        albumId: String,
        page: Int = 1,
        pageSize: Int = ProtocolConfig.XMLY_ALBUM_PAGE_SIZE,
        ascending: Bool = true
    ) async throws -> AlbumPage {
        let number = try xmlyIdentifier(albumId)
        try paging(
            page: page, pageSize: pageSize,
            maxPageSize: ProtocolConfig.XMLY_ALBUM_PAGE_SIZE
        )
        let payload = try await request(
            method: "GET", origin: XmlyOrigin.mobile.rawValue,
            path: "/mobile/v1/album/track/v2",
            query: [
                "albumId": number, "pageId": String(page),
                "pageSize": String(pageSize),
                "isAsc": ascending ? "true" : "false",
                "device": "android", "isQueryInvitationBrand": "true"
            ],
            account: false
        )
        guard let data = payload["data"] as? [String: Any] else {
            throw B1JSON.error(.invalidCatalogue)
        }
        // Minor：对应 Kotlin，先校验 totalCount，再检查 list。
        let count = try total(data["totalCount"], message: "专辑分页总数无效")
        guard let list = data["list"] as? [Any] else {
            throw B1JSON.error(.invalidCatalogue)
        }
        for (key, expected) in [("pageId", page), ("pageSize", pageSize)] {
            if let value = data[key],
               try total(value, message: "专辑分页无效") != expected {
                throw B1JSON.error(.invalidCatalogue)
            }
        }
        let offset = (page - 1) * pageSize
        let expected = min(pageSize, max(0, count - offset))
        // 对齐上游 d70b270：totalCount 略有滞后会导致尾页条数略少，
        // 仅在超出页容量或预期有数据却完全为空时报错。
        guard list.count <= pageSize && !(list.isEmpty && expected > 0) else {
            throw B1JSON.error(.incompleteCatalogue)
        }

        let header = payload["album"] as? [String: Any]
        // M3：Kotlin 头部 JSONObject.opt 的显式 null 不等于缺字段。
        try matchingAlbumHeader(header?["albumId"], number: number)
        try matchingAlbumHeader(data["albumId"], number: number)

        var seen: Set<String> = []
        var tracks: [Track] = []
        for (index, value) in list.enumerated() {
            guard let raw = value as? [String: Any] else {
                throw B1JSON.error(.invalidCatalogue)
            }
            for key in ["albumId", "album_id"] {
                // M3：Kotlin 声音行经 toPlainMap 后跳过 null。
                try matchingAlbum(raw[key], number: number)
            }
            let id = try xmlyIdentifier(
                B1JSON.text(B1JSON.first(raw, ["trackId", "id"]))
            )
            guard seen.insert(id).inserted else {
                throw B1JSON.error(.duplicatePage)
            }
            // 对齐上游 d70b270：order 仅作为展示元数据，容忍乱序或字段冲突，以服务端顺序为准。
            _ = try? albumOrder(raw)
            let position = offset + index + 1
            let official = ascending ? position : count - position + 1
            if let track = try trackFromApi(
                raw, albumId: number, officialPosition: official
            ) {
                tracks.append(track)
            }
        }

        // M1：Kotlin 为同步调用；Swift 必须传播辅助请求的取消。
        let detail = try await albumDetail(album: number)
        try Task.checkCancellation()
        let rawAlbum = (header ?? data).merging(detail) { _, detail in detail }
        var parsed = try albumFromApi(rawAlbum, id: number, total: count)
        let fallbackTitle = parsed.title.isEmpty
            ? (tracks.first(where: { !$0.album.isEmpty })?.album ?? "")
            : parsed.title
        let fallbackArtist = parsed.artist.isEmpty
            ? (tracks.first(where: { !$0.artist.isEmpty })?.artist ?? "")
            : parsed.artist
        let fallbackCover = parsed.coverUrl ?? tracks.first(where: { $0.coverUrl != nil })?.coverUrl
        if fallbackTitle != parsed.title || fallbackArtist != parsed.artist || fallbackCover != parsed.coverUrl {
            parsed = try Album(
                rawId: parsed.id, title: fallbackTitle, artist: fallbackArtist,
                intro: parsed.intro, coverUrl: fallbackCover,
                total: parsed.total, raw: parsed.raw
            )
        }
        cache(album: parsed)
        return AlbumPage(
            album: parsed, tracks: tracks, page: page,
            pageSize: pageSize, total: count
        )
    }

    func albumDetail(album: String) async throws -> [String: Any] {
        do {
            try Task.checkCancellation()
            let number = try xmlyIdentifier(album)
            let payload = try await request(
                method: "GET", origin: XmlyOrigin.mobile.rawValue,
                path: "/mobile-album/album/detail",
                query: ["albumId": number, "device": "android"],
                account: false
            )
            try Task.checkCancellation()
            guard let data = payload["data"] as? [String: Any],
                  var info = data["album"] as? [String: Any] else {
                return [:]
            }
            if let user = data["user"] as? [String: Any] {
                for key in ["nickname", "avatar"] {
                    if let value = user[key] as? String { info[key] = value }
                }
            }
            if let detail = data["detail"] as? [String: Any],
               let intro = detail["intro"] as? String, !intro.isEmpty {
                info["intro"] = intro
            }
            if let title = info["title"] as? String, !title.isEmpty {
                info["albumTitle"] = title
            }
            return info
        } catch let cancellation as CancellationError {
            // M1：Kotlin 的普通失败降级不能用于吞掉 Swift 取消。
            throw cancellation
        } catch {
            // M1：同时处理传输层以其他错误表达任务取消的情况。
            try Task.checkCancellation()
            // 对应 Kotlin runCatching：普通详情失败仍保留有效目录。
            return [:]
        }
    }

    func albumPageWith(
        albumId: String,
        trackId: String,
        maxPages: Int = 20
    ) async throws -> AlbumPage? {
        guard maxPages > 0 else { return nil }
        // Minor：有意接受输入 ID 校验比 Kotlin 更严格的契约；
        // Kotlin 在这里仅 substringAfter(':')。
        let wanted = try xmlyIdentifier(trackId)
        for page in 1...maxPages {
            let result = try await album(albumId: albumId, page: page)
            if result.tracks.contains(where: { $0.id == "xmly:" + wanted }) {
                return result
            }
            if page * result.pageSize >= result.total { return nil }
        }
        return nil
    }

    func track(number: String) async throws -> Track {
        let info = try await trackInfoMap(id: xmlyIdentifier(number))
        guard let track = try trackFromApi(info) else {
            throw B1JSON.error(.missingTrack)
        }
        return track
    }

    func trackComments(
        number: String,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> CommentPage {
        let id = try xmlyIdentifier(number)
        let size = min(30, max(1, pageSize))
        try paging(page: page, pageSize: size, maxPageSize: 30)
        let payload = try await request(
            method: "GET", origin: XmlyOrigin.search.rawValue,
            path: "/revision/comment/queryComments",
            query: [
                "trackId": id, "page": String(page), "pageSize": String(size)
            ],
            account: false
        )
        let data = payload["data"] as? [String: Any] ?? [:]
        let values = data["comments"] as? [Any] ?? []
        let comments: [Comment] = values.compactMap { value in
            // M6：每棵根评论独立预算，根节点深度为 1。
            var remainingNodes = 512
            return commentFromApi(
                value as? [String: Any],
                depth: 1, remainingNodes: &remainingNodes
            )
        }
        return CommentPage(
            comments: comments,
            page: xmlyJsonInt(data["currentPage"], default: page),
            totalPages: xmlyJsonInt(data["totalPage"], default: 0),
            total: xmlyJsonInt(data["totalComment"], default: comments.count)
        )
    }

    func resolve(
        number: String,
        quality: String = "auto"
    ) async throws -> ResolvedAudio {
        let requested = quality.lowercased()
        guard requested == "auto" || ProtocolConfig.qualities.contains(requested) else {
            throw B1JSON.error(.invalidQuality, definitive: true)
        }
        let id = try xmlyIdentifier(number)
        var info = try await trackInfoMap(id: id)
        var requiresReward = false
        if B1JSON.boolean(info["isPaid"]) != false,
           B1JSON.boolean(info["isAuthorized"]) != true {
            _ = try credentials()
            let current = try await activity(name: "config", seconds: nil)
            guard current.newDevice || current.remainingSeconds > 0 else {
                throw B1JSON.error(.insufficientQuota, definitive: true)
            }
            requiresReward = true
            info = try await trackInfoMap(id: id, reward: current)
            if B1JSON.boolean(info["isPaid"]) == false
                || B1JSON.boolean(info["isAuthorized"]) == true {
                requiresReward = false
            }
        }
        if B1JSON.boolean(info["isPreview"]) == true
            || B1JSON.boolean(info["isTrial"]) == true {
            throw B1JSON.error(.previewOnly, definitive: true)
        }

        var candidates: [String: String] = [:]
        func add(_ type: String, _ value: Any?) throws {
            guard candidates[type] == nil,
                  let text = value as? String, !text.isEmpty else { return }
            let decoded: String
            if text.hasPrefix("http://") || text.hasPrefix("https://") {
                decoded = text
            } else {
                decoded = try XmlyCrypto.decrypt(text, key: XmlyCrypto.playKey)
            }
            candidates[type] = try mediaUri(decoded)
        }

        let listValue = B1JSON.first(info, ["playUrlList"])
        // 对应 Kotlin：新建空表时 !listOnly || candidates.isEmpty() 恒真；
        // 直链优先，列表只补未覆盖的音质。
        try add("mp3_64", info["playUrl64"])
        try add("mp3_32", info["playUrl32"])
        if accountContext != nil, let listValue {
            let list: [Any]
            if let text = listValue as? String {
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: Data(text.utf8)
                ), let array = decoded as? [Any] else {
                    throw B1JSON.error(.invalidMedia)
                }
                list = array
            } else if let array = listValue as? [Any] {
                list = array
            } else {
                throw B1JSON.error(.invalidMedia)
            }
            for value in list {
                guard let item = value as? [String: Any] else { continue }
                let type = B1JSON.text(item["type"]).lowercased()
                guard ProtocolConfig.qualities.contains(type) else { continue }
                try add(type, item["url"])
            }
        }
        guard let fallback = ProtocolConfig.qualities.first(
            where: { candidates[$0] != nil }
        ) else {
            throw B1JSON.error(.permissionDenied, definitive: true)
        }
        let chosen = candidates[requested] == nil ? fallback : requested
        guard let track = try trackFromApi(info),
              var url = candidates[chosen] else {
            throw B1JSON.error(.missingTrack)
        }
        if !url.contains(".xmcdn.com/") {
            let redirected = await http.followRedirect(url: url)
            // M1：Kotlin 为同步调用；Swift followRedirect 取消时返回当前 URL。
            try Task.checkCancellation()
            url = try mediaUri(redirected)
        }
        try Task.checkCancellation()
        return ResolvedAudio(
            url: url, requiresReward: requiresReward, track: track,
            actualQuality: chosen, accountIdentity: identity
        )
    }

    func trackInfoMap(
        id: String,
        reward: Quota? = nil
    ) async throws -> [String: Any] {
        let number = try xmlyIdentifier(id)
        let info: [String: Any]
        if accountContext == nil {
            let payload = try await request(
                method: "GET", origin: XmlyOrigin.mobile.rawValue,
                path: "/mobile/track/\(number)",
                query: ["device": "android"], account: false
            )
            info = payload["data"] as? [String: Any] ?? payload
        } else {
            var params: [String: Any] = [
                "device": "android", "trackId": number
            ]
            if let reward {
                params["a1"] = reward.newDevice ? "1" : String(
                    min(ProtocolConfig.MAX_USAGE_SECONDS, max(0, reward.remainingSeconds))
                )
                params["a2"] = String(clock.now())
                params["a3"] = "0"
            }
            let encrypted = try XmlyCrypto.encrypt(
                B1JSON.encode(params), key: XmlyCrypto.playKey
            )
            let payload = try await request(
                method: "POST", origin: XmlyOrigin.mobile.rawValue,
                path: "/fmobile-track/fmobile/track/v2/baseInfo",
                json: ["data": encrypted], readOnly: true, signed: true
            )
            do {
                guard let body = payload["data"] as? String else {
                    throw B1JSON.error(.invalidAuthorization)
                }
                let decoded = try B1JSON.object(
                    XmlyCrypto.decrypt(body, key: XmlyCrypto.playKey),
                    code: .invalidAuthorization
                )
                info = try B1JSON.object(
                    decoded["trackInfo"], code: .invalidAuthorization
                )
            } catch {
                throw B1JSON.error(.invalidAuthorization)
            }
        }

        // M4：对应 Kotlin trackId ?: id ?: ""，只校验首个非 null 值。
        // Minor：对象／数组不能变为空串并绕过 invalid_id。
        let returned = try B1JSON.identifierText(
            B1JSON.first(info, ["trackId", "id"])
        )
        if !returned.isEmpty, try xmlyIdentifier(returned) != number {
            throw B1JSON.error(.idMismatch)
        }
        return info
    }

    func quota() async throws -> Quota {
        try await activity(name: "config", seconds: nil)
    }

    func debit(seconds: Int) async throws -> Quota {
        // Minor：Kotlin Int 的可表达上界为 Int32.max。
        guard seconds >= 1, seconds <= Int(Int32.max) else {
            throw B1JSON.error(.invalidDuration, definitive: true)
        }
        return try await activity(name: "report", seconds: seconds)
    }

    private func activity(name: String, seconds: Int?) async throws -> Quota {
        let context = try context()
        var params = [
            "deviceId": context["deviceId"] ?? "",
            "timestamp": String(clock.now()),
            "uid": context["uid"] ?? ""
        ]
        if let seconds { params["duration"] = String(seconds) }
        var body: [String: Any] = params
            .filter { $0.key != "uid" }
            .mapValues { $0 as Any }
        body["signature"] = XmlyCrypto.activitySignature(params)
        let payload = try await request(
            method: "POST", origin: XmlyOrigin.mobile.rawValue,
            path: "/lite-mobile/audi/func/v1/\(name)",
            json: body, readOnly: name == "config"
        )
        guard let data = payload["data"] as? [String: Any] else {
            throw B1JSON.error(.invalidQuota)
        }
        func decode(_ key: String) throws -> String {
            guard let encrypted = data[key] as? String else {
                throw B1JSON.error(.invalidQuota)
            }
            do {
                return try XmlyCrypto.decodeDurationField(
                    encrypted, nowMs: clock.now()
                )
            } catch {
                throw B1JSON.error(.invalidQuota)
            }
        }
        var newDevice = false
        // 对应 Kotlin：report 只解余额，不要求返回 newDevice。
        if name == "config" {
            let flag = try decode("newDevice")
            guard flag == "true" || flag == "false" else {
                throw B1JSON.error(.invalidQuota)
            }
            newDevice = flag == "true"
        }
        let remaining: Int
        if newDevice && data["availableListenDuration"] == nil {
            remaining = 0
        } else {
            let text = try decode("availableListenDuration")
            guard let parsed = Int32(text), parsed >= 0 else {
                throw B1JSON.error(.invalidQuota)
            }
            remaining = Int(parsed)
        }
        return try Quota(
            remainingSeconds: remaining, newDevice: newDevice,
            checkedAtMillis: clock.now()
        )
    }

    // M2：Kotlin 无门闩，此为 Swift 加严。门闩只保证互斥；
    // 调用进入队列的顺序即提交顺序，不按快照时间排序，
    // 因而不能保证旧快照不在新快照之后提交。
    func withTrackWrite(
        number: String,
        operation: () async throws -> Void
    ) async throws {
        let key = try xmlyIdentifier(number)
        try await trackWrites.acquire(key)
        // M1：交接与取消可能竞态；取得所有权后先建立 defer，
        // 再检查取消，确保未执行 operation 也会释放。
        defer { trackWrites.release(key) }
        try Task.checkCancellation()
        try await operation()
    }

    private func credentials() throws -> Credentials {
        guard let accountContext else {
            throw B1JSON.error(.loginRequired, definitive: true)
        }
        return try Credentials(
            token: accountContext.uid + "&" + accountContext.tokenAfterUID,
            deviceId: accountContext.deviceId
        )
    }

    private func matchingAlbumHeader(_ value: Any?, number: String) throws {
        // M3：Kotlin JSONObject.NULL.toString() 为 "null"，触发 invalid_id；
        // 字段不存在才跳过。
        guard let value else { return }
        guard !(value is NSNull) else {
            throw B1JSON.error(.invalidId, definitive: true)
        }
        guard try xmlyIdentifier(B1JSON.text(value)) == number else {
            throw B1JSON.error(.idMismatch)
        }
    }

    private func matchingAlbum(_ value: Any?, number: String) throws {
        // M3：对应 Kotlin 声音行 toPlainMap 后的 null 跳过语义。
        guard let value, !(value is NSNull) else { return }
        guard try xmlyIdentifier(B1JSON.text(value)) == number else {
            throw B1JSON.error(.idMismatch)
        }
    }

    private func trackFromApi(
        _ raw: [String: Any],
        albumId: String = "",
        officialPosition: Int? = nil
    ) throws -> Track? {
        // Minor：Kotlin 对对象／数组的非空文本调用 xmlyIdentifier，
        // 随后编号解析必然失败；直接报相同错误，避免序列化不可信树。
        let id = try B1JSON.identifierText(B1JSON.first(raw, ["trackId", "id"]))
        guard !id.isEmpty else { return nil }
        var rawMap = raw
        if let officialPosition { rawMap["officialPosition"] = officialPosition }
        let resolvedAlbum = albumId.isEmpty
            ? try B1JSON.identifierText(B1JSON.first(raw, ["albumId", "album_id"])) : albumId
        let duration: Double
        if let number = raw["duration"] as? NSNumber, !xmlyIsBoolean(number) {
            duration = number.doubleValue
        } else {
            duration = 0
        }
        let artistText: String = {
            let candidates: [Any?] = [
                raw["nickname"],
                raw["anchorNickName"],
                raw["anchorName"],
                (raw["anchorInfo"] as? [String: Any])?["nickname"],
                (raw["userInfo"] as? [String: Any])?["nickname"]
            ]
            for candidate in candidates {
                let text = B1JSON.text(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
            return ""
        }()
        let track = try Track(
            rawId: id,
            title: B1JSON.text(raw["title"]),
            artist: artistText,
            album: B1JSON.text(B1JSON.first(raw, ["albumTitle", "album_title"])),
            albumId: resolvedAlbum,
            duration: duration,
            orderNo: xmlyPositive(B1JSON.first(raw, ["orderNo", "orderNum", "order_no"])),
            episode: xmlyPositive(raw["episode"]),
            isPaid: B1JSON.boolean(raw["isPaid"]) ?? B1JSON.boolean(raw["is_paid"]),
            isAuthorized: B1JSON.boolean(raw["isAuthorized"]),
            coverUrl: coverUrl(raw),
            intro: B1JSON.text(raw["intro"]),
            raw: publicRaw(rawMap).mapValues { Optional($0) }
        )
        cache(track: track)
        return track
    }

    private func albumFromApi(
        _ raw: [String: Any],
        id: String,
        total: Int = 0
    ) throws -> Album {
        try Album(
            rawId: id,
            title: B1JSON.text(B1JSON.first(raw, ["albumTitle", "album_title", "title"])),
            artist: B1JSON.text(B1JSON.first(raw, ["nickname", "artist"])),
            intro: B1JSON.text(raw["intro"]),
            coverUrl: coverUrl(raw), total: total,
            raw: publicRaw(raw).mapValues { Optional($0) }
        )
    }

    private func commentFromApi(
        _ raw: [String: Any]?,
        depth: Int,
        remainingNodes: inout Int
    ) -> Comment? {
        // M6：Kotlin 无条件递归、无上限。Swift 有意限制根深度为 1、
        // 最大深度 8、每棵树最多访问 512 个对象节点（含空内容节点）。
        // 预算用尽即截断；此有意偏差需由执行侧同步记录到 BUILD.md。
        guard depth <= 8, remainingNodes > 0, let raw else { return nil }
        remainingNodes -= 1
        let content = B1JSON.text(raw["content"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let original = B1JSON.text(raw["smallHeader"])
        let avatar = original.hasPrefix("//") ? "https:" + original : original
        var replies: [Comment] = []
        if depth < 8 {
            for value in raw["replies"] as? [Any] ?? [] {
                guard remainingNodes > 0 else { break }
                if let reply = commentFromApi(
                    value as? [String: Any],
                    depth: depth + 1, remainingNodes: &remainingNodes
                ) {
                    replies.append(reply)
                }
            }
        }
        let id = B1JSON.text(raw["id"])
        let uid = B1JSON.text(raw["uid"])
        return Comment(
            id: id == "null" ? "" : id,
            uid: uid == "null" ? "" : uid,
            nickname: B1JSON.text(raw["nickname"]),
            avatarUrl: avatar.hasPrefix("https://") ? avatar : nil,
            content: content, createdAt: B1JSON.text(raw["createAt"]),
            likes: xmlyJsonInt(raw["likes"], default: 0),
            replyCount: xmlyJsonInt(raw["replyCount"], default: 0),
            replies: replies
        )
    }

    private func albumOrder(_ raw: [String: Any]) throws -> Int? {
        var order: Int?
        for key in ["orderNo", "orderNum", "order_no"] {
            guard let value = xmlyPositive(raw[key]) else { continue }
            if let order, order != value {
                throw B1JSON.error(.invalidCatalogue)
            }
            order = value
        }
        return order
    }

    private func paging(
        page: Int,
        pageSize: Int,
        maxPageSize: Int = 50
    ) throws {
        guard (1...10_000).contains(page),
              (1...maxPageSize).contains(pageSize) else {
            throw B1JSON.error(.invalidPage, definitive: true)
        }
    }

    private func total(_ value: Any?, message: String) throws -> Int {
        let number: Double?
        if let value = value as? NSNumber, !xmlyIsBoolean(value) {
            number = value.doubleValue
        } else if let value = value as? String {
            // B1 N2 订正：JVM `toDoubleOrNull` 接受首尾空白与 f/d 后缀
            //（见 B1JSON.jvmDouble），此前“拒绝空白与 f 后缀”的裁决有误。
            number = B1JSON.jvmDouble(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite, number >= 0,
              number.rounded(.down) == number else {
            throw XmlyError.failure(code: .invalidPage, message: message)
        }
        // Kotlin Double.toInt 对超出 Int32 的有限值饱和。
        return number >= Double(Int32.max) ? Int(Int32.max) : Int(number)
    }

    private func cache(album: Album) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if albums[album.id] == nil { albumKeys.append(album.id) }
        albums[album.id] = album
        if albumKeys.count > 512 {
            albums.removeValue(forKey: albumKeys.removeFirst())
        }
    }

    private func cache(track: Track) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if metadata[track.number] == nil { metadataKeys.append(track.number) }
        metadata[track.number] = track
        // Minor 核实：Kotlin removeEldestEntry 同样限制 metadata 为 512。
        if metadataKeys.count > 512 {
            metadata.removeValue(forKey: metadataKeys.removeFirst())
        }
    }
}

// S2 Round B2：供 Experience 的 requireAccount 使用；
// 访问同文件 private accountContext。
extension XmlyClientService {
    var hasAccount: Bool { accountContext != nil }
}

// NSLock 只用于同步状态操作，绝不持锁跨 await。
private final class XmlyTrackWriteGate {
    private static let registryLock = NSLock()
    private static var registry: [String: XmlyTrackWriteGate] = [:]

    static func shared(for identity: String) -> XmlyTrackWriteGate {
        // M2：Kotlin 无门闩；Swift 按账号 identity 共享互斥范围。
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[identity] { return existing }
        let gate = XmlyTrackWriteGate()
        registry[identity] = gate
        return gate
    }

    private final class Waiter {
        enum State {
            case initial
            case queued
            case acquired
            case cancelled
        }

        // M1：这些字段只允许在所属 gate 的 lock 内访问。
        var state: State = .initial
        var continuation: CheckedContinuation<Void, Error>?
    }

    private let lock = NSLock()
    // 键存在表示有持有者；数组只包含尚未获得所有权的等待者。
    private var queues: [String: [Waiter]] = [:]

    func acquire(_ key: String) async throws {
        let waiter = Waiter()
        // M1：Kotlin 同步实现没有任务取消；Swift 显式仲裁注册、取消与交接。
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                enqueue(key, waiter: waiter, continuation: continuation)
            }
        }, onCancel: {
            self.cancel(key, waiter: waiter)
        })
    }

    private func enqueue(
        _ key: String,
        waiter: Waiter,
        continuation: CheckedContinuation<Void, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch waiter.state {
        case .cancelled:
            // M1：取消可早于 continuation 注册，此处唯一一次恢复。
            continuation.resume(throwing: CancellationError())
        case .initial:
            if queues[key] == nil {
                queues[key] = []
                waiter.state = .acquired
                continuation.resume()
            } else {
                waiter.state = .queued
                waiter.continuation = continuation
                queues[key, default: []].append(waiter)
            }
        case .queued, .acquired:
            preconditionFailure("写入等待者不能重复注册")
        }
    }

    private func cancel(_ key: String, waiter: Waiter) {
        lock.lock()
        defer { lock.unlock() }
        switch waiter.state {
        case .initial:
            waiter.state = .cancelled
        case .queued:
            // M1：移除与恢复均在同一把锁内，与 release 互斥。
            queues[key]?.removeAll { $0 === waiter }
            let continuation = waiter.continuation
            waiter.continuation = nil
            waiter.state = .cancelled
            continuation?.resume(throwing: CancellationError())
        case .acquired, .cancelled:
            // 已交接者由 withTrackWrite 的取消检查与 defer 释放；
            // 已取消者不能再次恢复。
            break
        }
    }

    func release(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var waiting = queues[key] else { return }
        if waiting.isEmpty {
            queues.removeValue(forKey: key)
        } else {
            let next = waiting.removeFirst()
            queues[key] = waiting
            let continuation = next.continuation
            next.continuation = nil
            next.state = .acquired
            continuation?.resume()
        }
    }
}

// 两个服务共用的内部 JSON 辅助，不承载账号或可变全局状态。
enum B1JSON {
    /// 按 JVM `Double.parseDouble`（Kotlin `String.toDoubleOrNull` 委托目标）
    /// 解析字符串：首尾按 `String.trim()` 去空白（U+0020 及以下），接受一个
    /// 尾随 f/F/d/D 类型后缀（数值直接转 double，不经过 float）；其余与
    /// Swift `Double` 相同。十六进制浮点（`0x…p…`）JVM 接受而 Swift 不接受，
    /// 属已知残留差距（见 BUILD.md §11）；`"inf"` JVM 不接受，此处同样拒绝。
    static func jvmDouble(_ value: String) -> Double? {
        let scalars = Array(value.unicodeScalars)
        var start = scalars.startIndex
        while start < scalars.endIndex, scalars[start].value <= 32 {
            start = scalars.index(after: start)
        }
        var end = scalars.endIndex
        while end > start, scalars[scalars.index(before: end)].value <= 32 {
            end = scalars.index(before: end)
        }
        guard start < end else { return nil }
        var text = String(String.UnicodeScalarView(scalars[start..<end]))
        if let last = text.last, "fFdD".contains(last) {
            let base = String(text.dropLast())
            let lower = base.lowercased()
            guard !base.isEmpty,
                  lower != "nan", lower != "+nan", lower != "-nan",
                  lower != "infinity",
                  lower != "+infinity", lower != "-infinity",
                  lower != "inf", lower != "+inf", lower != "-inf" else {
                return nil
            }
            text = base
        }
        let lower = text.lowercased()
        guard lower != "inf", lower != "+inf", lower != "-inf" else {
            return nil
        }
        // JVM 的特殊值只认确切大小写：`nan`/`infinity` 小写应拒绝。
        if lower == "nan" || lower == "+nan" || lower == "-nan" {
            return (text == "NaN" || text == "+NaN" || text == "-NaN")
                ? Double.nan : nil
        }
        if lower == "infinity" || lower == "+infinity" || lower == "-infinity" {
            guard text == "Infinity" || text == "+Infinity"
                    || text == "-Infinity" else {
                return nil
            }
        }
        return Double(text)
    }

    static func error(
        _ code: XmlyError.Code,
        definitive: Bool = false
    ) -> XmlyError {
        // Minor：对应 Kotlin 各错误码语义，每个码固定中文文案；
        // 不拼接响应、凭据、URL 或服务端错误原文。
        let message: String
        switch code {
        case .invalidEncoding: message = "编码格式无效"
        case .loginRequired: message = "请先登录"
        case .loginExpired: message = "登录已过期，请重新登录"
        case .permissionDenied: message = "当前没有获得完整音频地址，请检查听时与版权权限"
        case .rejected: message = "请求未被接受"
        case .badTimestamp: message = "请求时间无效"
        case .rateLimited: message = "请求过于频繁，请稍后重试"
        case .network: message = "网络请求失败"
        case .uncertain: message = "请求结果未能确认"
        case .invalidJSON: message = "JSON 数据格式无效"
        case .responseTooLarge: message = "响应数据过大"
        case .protocolError: message = "接口协议无效"
        case .invalidCredentials: message = "登录信息格式无效"
        case .invalidPage: message = "分页参数无效"
        case .invalidResponse: message = "接口响应无效"
        case .invalidMobile: message = "手机号码无效"
        case .invalidCaptcha: message = "图形验证信息无效"
        case .invalidCode: message = "验证码无效"
        case .invalidQuota: message = "听时信息缺失或已过期"
        case .invalidAuthorization: message = "授权声音信息无效"
        case .invalidMedia: message = "音频地址或列表格式无效"
        case .invalidHistory: message = "历史记录或同步参数无效"
        case .invalidId: message = "喜马拉雅编号无效"
        case .missingAccount: message = "账号不存在"
        case .invalidSearch: message = "请输入 1..200 字的关键词并选择有效类型"
        case .invalidCatalogue: message = "专辑或搜索目录无效"
        case .incompleteCatalogue: message = "专辑分页不完整，请刷新重试"
        case .idMismatch: message = "返回信息与请求编号不匹配"
        case .duplicatePage: message = "专辑声音重复，请刷新重试"
        case .missingTrack: message = "声音信息缺失"
        case .invalidQuality: message = "音质设置无效"
        case .insufficientQuota: message = "听时不足，请前往官方 App 获取听时"
        case .previewOnly: message = "仅获得试听音频，不能下载完整声音"
        case .invalidDuration: message = "听时必须为 1..2147483647 的整数秒"
        case .authRequired: message = "历史同步需要有效的极速版登录态"
        case .repeatedPage: message = "历史服务返回重复分页"
        case .historyLimit: message = "历史记录超过 5000 条上限"
        case .historyUnconfirmed: message = "未能确认历史进度同步"
        // S2 Round B2（Kotlin XmlyLogin／XmlyExperience）：
        case .invalidDevice: message = "登录设备标识无效"
        case .captchaReused: message = "本次安全验证已使用，请重新验证"
        case .smsCooldown:
            // Swift 有意使用固定文案；Kotlin 显示动态剩余秒数。
            message = "短信发送过于频繁，请稍后再试"
        case .challengeInvalid: message = "短信验证已取消或无效"
        case .challengeExpired: message = "短信验证已过期，请重新发送"
        case .httpError: message = "登录服务请求失败"
        case .networkError: message = "登录连接失败或超时，请勿自动重发短信"
        case .smsSendRejected, .smsVerifyRejected, .quickLoginRejected, .nonceRejected:
            message = "登录请求未成功，请重新验证"
        case .invalidHome: message = "首页数据无效"
        case .missingAlbum: message = "缺少专辑标识"
        case .profileUnavailable: message = "账号资料不可用"
        }
        return .failure(code: code, message: message, definitive: definitive)
    }

    static func first(_ raw: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = raw[key], !(value is NSNull) { return value }
        }
        return nil
    }

    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if xmlyIsBoolean(number) { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return ""
    }

    static func identifierText(_ value: Any?) throws -> String {
        guard let value, !(value is NSNull) else { return "" }
        // Minor：Kotlin 对对象／数组的 toString 产生非空文本，
        // 随后编号解析必然失败；直接报相同错误，避免序列化不可信树。
        guard value is String || value is NSNumber else {
            throw error(.invalidId, definitive: true)
        }
        return text(value)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, xmlyIsBoolean(number) else {
            return nil
        }
        return number.boolValue
    }

    static func object(
        _ value: Any?,
        code: XmlyError.Code
    ) throws -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        if let text = value as? String,
           let object = try? JSONSerialization.jsonObject(
               with: Data(text.utf8)
           ) as? [String: Any] {
            return object
        }
        throw error(code)
    }

    static func encode(_ value: Any) throws -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw self.error(.invalidJSON)
        }
    }
}

struct TrackCaptionLine: Equatable, Sendable, Identifiable {
    let id: Int
    let timeMs: Int64?
    let text: String
}

struct TrackCaptions: Equatable, Sendable {
    let lines: [TrackCaptionLine]
    let isTimed: Bool
    let sourceLabel: String

    static let empty = TrackCaptions(lines: [], isTimed: false, sourceLabel: "")

    func activeLineIndex(at positionMs: Int64) -> Int? {
        guard isTimed else { return nil }
        var matched: Int?
        for (idx, line) in lines.enumerated() {
            if let t = line.timeMs, t <= positionMs {
                matched = idx
            } else if let t = line.timeMs, t > positionMs {
                break
            }
        }
        return matched
    }
}

struct TrackDetailSummary: Equatable, Sendable {
    let captions: TrackCaptions
    let commentCount: Int?
}

extension XmlyClientService {
    /// 一次请求同时拉取声音字幕／章节文稿与评论总数；必要时回退 Web 端 simple 接口补全文稿。
    func trackDetailSummary(number: String, fallbackIntro: String = "") async throws -> TrackDetailSummary {
        let id = try xmlyIdentifier(number)
        let payload = try await request(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/mobile/track/\(id)",
            query: ["device": "android"],
            account: false
        )
        let info = (payload["data"] as? [String: Any]) ?? payload
        let lyric = (info["lyric"] as? String) ?? ""
        let richIntro = (info["richIntro"] as? String)
            ?? (info["shortRichIntro"] as? String)
            ?? ""
        let intro = (info["intro"] as? String) ?? fallbackIntro
        let rawComments = info["comments"] ?? info["commentCount"] ?? info["commentsCount"]
        let commentCount: Int? = rawComments.flatMap { xmlyOptInt($0) }.map { max(0, $0) }

        var captions = Self.parseCaptions(lyric: lyric, richIntro: richIntro, intro: intro)
        if captions.lines.isEmpty {
            // 回退尝试 Web 端 simple 接口补全 richIntro/shortIntro
            if let webPayload = try? await request(
                method: "GET",
                origin: XmlyOrigin.search.rawValue,
                path: "/revision/track/simple",
                query: ["trackId": id],
                account: false
            ),
               let data = webPayload["data"] as? [String: Any],
               let trackInfo = data["trackInfo"] as? [String: Any] {
                let webRich = (trackInfo["richIntro"] as? String)
                    ?? (trackInfo["shortIntro"] as? String)
                    ?? ""
                let webIntro = (trackInfo["intro"] as? String) ?? ""
                let webCaptions = Self.parseCaptions(lyric: "", richIntro: webRich, intro: webIntro)
                if !webCaptions.lines.isEmpty {
                    captions = webCaptions
                }
            }
        }
        return TrackDetailSummary(captions: captions, commentCount: commentCount)
    }

    /// 获取声音的同步字幕（LRC）或富文本／纯文本章节文稿。
    func trackCaptions(number: String, fallbackIntro: String = "") async throws -> TrackCaptions {
        try await trackDetailSummary(number: number, fallbackIntro: fallbackIntro).captions
    }

    static func parseCaptions(
        lyric: String,
        richIntro: String,
        intro: String
    ) -> TrackCaptions {
        let trimmedLyric = lyric.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLyric.isEmpty {
            let timed = parseLRC(trimmedLyric)
            if !timed.isEmpty {
                return TrackCaptions(lines: timed, isTimed: true, sourceLabel: "同步字幕")
            }
            let plain = splitNonEmptyLines(trimmedLyric)
            if !plain.isEmpty {
                return TrackCaptions(lines: plain, isTimed: false, sourceLabel: "字幕文本")
            }
        }

        let cleanedRich = stripHTML(richIntro)
        if !cleanedRich.isEmpty {
            let lines = splitNonEmptyLines(cleanedRich)
            if !lines.isEmpty {
                return TrackCaptions(lines: lines, isTimed: false, sourceLabel: "声音文稿")
            }
        }

        let cleanedIntro = stripHTML(intro)
        if !cleanedIntro.isEmpty {
            let lines = splitNonEmptyLines(cleanedIntro)
            if !lines.isEmpty {
                return TrackCaptions(lines: lines, isTimed: false, sourceLabel: "声音简介")
            }
        }

        return .empty
    }

    private static func parseLRC(_ text: String) -> [TrackCaptionLine] {
        // 匹配 [mm:ss.xx] / [mm:ss.xxx] / [mm:ss]
        guard let regex = try? NSRegularExpression(
            pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        ) else {
            return []
        }
        var entries: [(timeMs: Int64, text: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = regex.matches(
                in: rawLine,
                range: NSRange(location: 0, length: nsLine.length)
            )
            guard !matches.isEmpty else { continue }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = nsLine.substring(from: lastEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            for match in matches {
                let mins = Int64(nsLine.substring(with: match.range(at: 1))) ?? 0
                let secs = Int64(nsLine.substring(with: match.range(at: 2))) ?? 0
                var fracMs: Int64 = 0
                if match.range(at: 3).location != NSNotFound {
                    let fracStr = nsLine.substring(with: match.range(at: 3))
                    if let val = Int64(fracStr) {
                        if fracStr.count == 1 { fracMs = val * 100 }
                        else if fracStr.count == 2 { fracMs = val * 10 }
                        else { fracMs = val }
                    }
                }
                let totalMs = (mins * 60 + secs) * 1_000 + fracMs
                entries.append((totalMs, body))
            }
        }
        entries.sort { $0.timeMs < $1.timeMs }
        return entries.enumerated().map { idx, item in
            TrackCaptionLine(id: idx, timeMs: item.timeMs, text: item.text)
        }
    }

    private static func stripHTML(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
        for pattern in [#"<br\s*/?>"#, #"</p>"#, #"</div>"#, #"</li>"#] {
            text = text.replacingOccurrences(
                of: pattern, with: "\n", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitNonEmptyLines(_ text: String) -> [TrackCaptionLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { TrackCaptionLine(id: $0.offset, timeMs: nil, text: $0.element) }
    }
}
