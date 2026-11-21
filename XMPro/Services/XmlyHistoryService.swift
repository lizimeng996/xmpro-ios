
import Foundation

final class XmlyHistoryService {
    private let client: XmlyClientService
    private let clock: ServerClock
    private let maximumTimestamp: Int64 = 2_115_354_119_000

    init(client: XmlyClientService, clock: ServerClock = .shared) {
        self.client = client
        self.clock = clock
    }

    func records() async throws -> [HistoryRecord] {
        let context = try validatedContext()
        var items: [String: HistoryRecord] = [:]
        // M5：对应 Kotlin LinkedHashMap 的首次插入顺序；
        // 用较新记录替换旧值不改变该声音的序号。
        var firstSeen: [String: Int] = [:]
        var fingerprints: Set<String> = []

        for page in 1...50 {
            let response = try await client.request(
                method: "GET", origin: XmlyOrigin.mobile.rawValue,
                path: "/nyx/v1/history/query/android",
                query: [
                    "pageId": String(page), "pageSize": "100",
                    "syncPoint": "0", "timeStamp": String(clock.now()),
                    "uid": context["uid"] ?? ""
                ]
            )
            let data = try B1JSON.object(response["data"], code: .invalidHistory)
            guard let raw = data["listenModels"] as? [Any],
                  let more = B1JSON.boolean(data["hasMore"]),
                  raw.count <= 100 else {
                throw B1JSON.error(.invalidHistory)
            }
            if !raw.isEmpty {
                // 固定键序避免对象键排列差异绕过重复页检测。
                let fingerprint = ProtocolBytes.sha256Hex(try B1JSON.encode(raw))
                guard fingerprints.insert(fingerprint).inserted else {
                    throw B1JSON.error(.repeatedPage)
                }
            }
            for value in raw {
                guard let object = value as? [String: Any],
                      let record = normalize(object) else { continue }
                let id = record.track.id
                if firstSeen[id] == nil {
                    firstSeen[id] = firstSeen.count
                }
                if let existing = items[id],
                   existing.updatedAt >= record.updatedAt {
                    continue
                }
                items[id] = record
            }
            if !more {
                // M5：对应 Kotlin 稳定 sortedByDescending；
                // 时间平局时保留首次出现顺序，progress 因而选中相同声音。
                return items.values.sorted {
                    if $0.updatedAt != $1.updatedAt {
                        return $0.updatedAt > $1.updatedAt
                    }
                    return firstSeen[$0.track.id, default: Int.max]
                        < firstSeen[$1.track.id, default: Int.max]
                }
            }
            guard !raw.isEmpty else { throw B1JSON.error(.invalidHistory) }
        }
        throw B1JSON.error(.historyLimit)
    }

    func progress(
        albumId: String = "",
        trackId: String = ""
    ) async throws -> HistoryRecord? {
        guard !albumId.isEmpty || !trackId.isEmpty else {
            throw B1JSON.error(.invalidHistory, definitive: true)
        }
        let album = albumId.isEmpty ? "" : try xmlyIdentifier(albumId)
        let track = trackId.isEmpty ? "" : try xmlyIdentifier(trackId)
        return try await records().first {
            (album.isEmpty || $0.track.albumKey == album)
                && (track.isEmpty || $0.track.number == track)
        }
    }

    func sync(
        track: Track,
        positionSeconds: Double,
        startedAtMs: Int64,
        endedAtMs: Int64
    ) async throws {
        guard track.id.hasPrefix("xmly:"),
              positionSeconds.isFinite,
              (0...2_147_483_647).contains(positionSeconds),
              startedAtMs > 0,
              startedAtMs <= endedAtMs,
              endedAtMs <= maximumTimestamp,
              !track.albumKey.isEmpty else {
            throw B1JSON.error(.invalidHistory, definitive: true)
        }
        let position = track.duration.isFinite && track.duration > 0
            ? min(positionSeconds, track.duration) : positionSeconds
        let ended = endedAtMs == startedAtMs
            ? max(clock.now(), startedAtMs) : endedAtMs

        // Kotlin Number.toInt；非数字（包括布尔、字符串）取默认方向 0。
        let rawDirection: Any? = track.raw["direction"] ?? nil
        let direction: Int
        if let number = rawDirection as? NSNumber, !xmlyIsBoolean(number) {
            direction = xmlyJsonInt(number, default: 0)
        } else {
            direction = 0
        }
        guard direction == 0 || direction == 1 else {
            throw B1JSON.error(.invalidHistory, definitive: true)
        }

        let record: [String: Any] = [
            "endedAt": String(ended),
            "startedAt": String(startedAtMs),
            "type": "1",
            "itemId": track.albumKey,
            "childId": track.number,
            "breakSecond": String(Int(position)),
            "direction": direction
        ]
        let mergeRecords = try B1JSON.encode([record])
        let context = try validatedContext()
        var signatureParams = context
        signatureParams["mergeRecords"] = mergeRecords
        let form = [
            "mergeRecords": mergeRecords,
            "signature": Signatures.history(signatureParams)
        ]

        // M2：Kotlin 无门闩；Swift 按账号、规范化声音编号跨 client 互斥。
        // 只保证进入队列的调用按序提交，不根据快照新旧重排。
        try await client.withTrackWrite(number: track.number) {
            let response = try await self.client.request(
                method: "POST", origin: XmlyOrigin.collector.rawValue,
                path: "/nyx/v1/history/merge/android",
                form: form,
                // 保留 Kotlin 的实际调用参数。
                readOnly: true
            )
            let data = try B1JSON.object(response["data"], code: .invalidHistory)
            guard let point = Int64(B1JSON.text(data["syncPoint"])), point >= 0 else {
                throw B1JSON.error(.historyUnconfirmed)
            }
        }
    }

    private func validatedContext() throws -> [String: String] {
        let context = try client.context()
        guard ProtocolBytes.fullMatch(
            #"^[1-9][0-9]*$"#, context["uid"] ?? ""
        ) else {
            throw B1JSON.error(.authRequired, definitive: true)
        }
        return context
    }

    private func normalize(_ raw: [String: Any]) -> HistoryRecord? {
        let type = xmlyJsonLong(raw["type"], default: 0)
        guard type == 1 || type == 9,
              xmlyJsonLong(raw["deleteTime"], default: 0) <= 0,
              let trackID = try? xmlyIdentifier(B1JSON.text(raw["childId"])),
              let albumID = try? xmlyIdentifier(B1JSON.text(raw["itemId"])) else {
            return nil
        }

        let duration = min(
            Int64(Int32.max), max(0, xmlyJsonLong(raw["length"], default: 0))
        )
        var position = Double(min(
            Int64(Int32.max), max(0, xmlyJsonLong(raw["breakSecond"], default: 0))
        ))
        if duration > 0 { position = min(position, Double(duration)) }
        let plain: [String: Any] = [
            "albumId": albumID,
            "cover_url": B1JSON.text(raw["itemCoverUrl"])
        ]
        guard let track = try? Track(
            rawId: trackID,
            title: B1JSON.text(raw["childTitle"]),
            album: B1JSON.text(raw["itemTitle"]),
            albumId: albumID,
            duration: Double(duration),
            coverUrl: coverUrl(plain),
            raw: publicRaw(plain).mapValues { Optional($0) }
        ) else { return nil }

        return HistoryRecord(
            track: track,
            positionSeconds: position,
            updatedAt: min(
                maximumTimestamp,
                max(0, xmlyJsonLong(raw["endedAt"], default: 0))
            )
        )
    }
}
