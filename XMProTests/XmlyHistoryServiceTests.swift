
import Foundation
import XCTest
@testable import XMPro

final class XmlyHistoryServiceTests: XCTestCase {
    private func row(
        _ id: Int,
        ended: Int64,
        type: Int = 1,
        deleted: Int = 0,
        duration: Int = 100,
        position: Int = 20
    ) -> [String: Any] {
        [
            "type": type, "deleteTime": deleted, "childId": id, "itemId": 7,
            "childTitle": "合成声音", "itemTitle": "合成专辑",
            "itemCoverUrl": "//fixture.xmcdn.com/cover",
            "length": duration, "breakSecond": position, "endedAt": ended
        ]
    }

    private func service(_ fake: FakeHTTPTransport) throws -> XmlyHistoryService {
        XmlyHistoryService(
            client: XmlyClientService(
                http: fake, accountContext: try B1Fixture.context(),
                clock: B1Fixture.clock()
            ),
            clock: B1Fixture.clock()
        )
    }

    func testRecordsPaginationDeduplicationAndOrder() async throws {
        let first: [String: Any] = [
            "listenModels": [row(1, ended: 100), row(2, ended: 300)],
            "hasMore": true
        ]
        let second = try B1Fixture.json([
            "listenModels": [row(1, ended: 400), row(3, ended: 200)],
            "hasMore": false
        ])
        let fake = FakeHTTPTransport { _, index in
            index == 1 ? ["data": first] : ["data": second]
        }
        let history = try service(fake)
        let records = try await history.records()
        b1Check(records.map(\.track.number) == ["1", "2", "3"], "history-order")
        b1Check(records.map(\.updatedAt) == [400, 300, 200], "history-newest")
        b1Check(fake.calls.count == 2, "history-end")
        b1Check(
            fake.calls.map { $0.query["pageId"] } == ["1", "2"],
            "history-pages"
        )
        b1Check(
            fake.calls.allSatisfy {
                $0.query["pageSize"] == "100"
                    && $0.query["syncPoint"] == "0"
                    && $0.query["timeStamp"] == String(B1Fixture.now)
            },
            "history-query"
        )
    }

    func testRepeatedPage() async throws {
        let data: [String: Any] = [
            "listenModels": [row(1, ended: 100)], "hasMore": true
        ]
        let fake = FakeHTTPTransport { _, _ in ["data": data] }
        let history = try service(fake)
        await b1ExpectError("repeated_page", "history-repeated") {
            _ = try await history.records()
        }
        b1Check(fake.calls.count == 2, "history-repeated-count")
    }

    func testInvalidPageShapes() async throws {
        let oversized = (1...101).map { row($0, ended: Int64($0)) }
        let cases: [[String: Any]] = [
            ["hasMore": false],
            ["listenModels": []],
            ["listenModels": [], "hasMore": true],
            ["listenModels": [], "hasMore": "false"],
            ["listenModels": oversized, "hasMore": false]
        ]
        for data in cases {
            let history = try service(
                FakeHTTPTransport { _, _ in ["data": data] }
            )
            await b1ExpectError("invalid_history", "history-shape") {
                _ = try await history.records()
            }
        }
    }

    func testEmptyFinalPageEnds() async throws {
        let fake = FakeHTTPTransport { _, _ in
            ["data": ["listenModels": [], "hasMore": false]]
        }
        let records = try await service(fake).records()
        b1Check(records.isEmpty && fake.calls.count == 1, "history-empty-final")
    }

    func testHistoryLimit() async throws {
        let fake = FakeHTTPTransport { _, index in
            [
                "data": [
                    "listenModels": [[
                        "type": 1, "childId": index, "itemId": 7,
                        "endedAt": index
                    ]],
                    "hasMore": true
                ]
            ]
        }
        let history = try service(fake)
        await b1ExpectError("history_limit", "history-limit") {
            _ = try await history.records()
        }
        b1Check(fake.calls.count == 50, "history-limit-count")
    }

    func testNormalizeFilteringAndClamps() async throws {
        var invalidID = row(6, ended: 200)
        invalidID["childId"] = "invalid"
        let rows = [
            row(1, ended: 3_000_000_000_000, type: 9, duration: 30, position: 90),
            row(2, ended: 200, type: 2),
            row(3, ended: 200, deleted: 1),
            row(4, ended: -20, duration: -1, position: -1),
            row(5, ended: 100, duration: 0, position: Int(Int32.max) + 100),
            invalidID
        ]
        let fake = FakeHTTPTransport { _, _ in
            ["data": ["listenModels": rows, "hasMore": false]]
        }
        let records = try await service(fake).records()
        b1Check(records.count == 3, "normalize-count")
        let first = records.first { $0.track.number == "1" }
        b1Check(
            first?.positionSeconds == 30
                && first?.updatedAt == 2_115_354_119_000
                && first?.track.duration == 30,
            "normalize-upper"
        )
        b1Check(
            first?.track.title == "合成声音"
                && first?.track.album == "合成专辑"
                && first?.track.coverUrl == "https://fixture.xmcdn.com/cover",
            "normalize-track"
        )
        let lower = records.first { $0.track.number == "4" }
        b1Check(
            lower?.positionSeconds == 0
                && lower?.updatedAt == 0
                && lower?.track.duration == 0,
            "normalize-lower"
        )
        b1Check(
            records.first { $0.track.number == "5" }?.positionSeconds
                == Double(Int32.max),
            "normalize-position-cap"
        )
    }

    func testProgressFiltersAndValidation() async throws {
        let rows = [row(1, ended: 100), row(2, ended: 200)]
        let fake = FakeHTTPTransport { _, _ in
            ["data": ["listenModels": rows, "hasMore": false]]
        }
        let history = try service(fake)
        let album = try await history.progress(albumId: "xmly:7")
        let track = try await history.progress(trackId: "xmly:1")
        b1Check(album?.track.number == "2", "progress-album")
        b1Check(track?.track.number == "1", "progress-track")
        await b1ExpectError("invalid_history", "progress-empty", definitive: true) {
            _ = try await history.progress()
        }
    }

    func testSyncRecordTypesSignatureAndConfirmation() async throws {
        let context = try B1Fixture.context()
        let fake = FakeHTTPTransport { _, _ in
            ["data": "{\"syncPoint\":\"123\"}"]
        }
        let client = XmlyClientService(
            http: fake, accountContext: context, clock: B1Fixture.clock()
        )
        let history = XmlyHistoryService(client: client, clock: B1Fixture.clock())
        let track = try Track(
            rawId: "1", albumId: "7", duration: 40,
            raw: ["direction": NSNumber(value: 1)]
        )
        try await history.sync(
            track: track, positionSeconds: 52.9,
            startedAtMs: B1Fixture.now - 1_000,
            endedAtMs: B1Fixture.now - 1_000
        )

        guard let call = fake.calls.first,
              let encoded = call.form["mergeRecords"],
              let array = try JSONSerialization.jsonObject(
                  with: Data(encoded.utf8)
              ) as? [[String: Any]],
              let record = array.first else {
            XCTFail("sync-record")
            return
        }
        b1Check(array.count == 1, "sync-single")
        let direction = record["direction"] as? NSNumber
        b1Check(
            direction != nil
                && direction.map { !xmlyIsBoolean($0) && $0.intValue == 1 } == true
                && !(record["direction"] is String),
            "sync-direction"
        )
        b1Check(record["breakSecond"] as? String == "40", "sync-position")
        b1Check(record["type"] as? String == "1", "sync-type")
        b1Check(
            record["startedAt"] as? String == String(B1Fixture.now - 1_000)
                && record["endedAt"] as? String == String(B1Fixture.now),
            "sync-bounds"
        )
        b1Check(
            record["itemId"] as? String == "7"
                && record["childId"] as? String == "1",
            "sync-ids"
        )

        // 独立构造全部签名参数；仅用布尔比较，不输出签名或上下文。
        var expectedParams: [String: String] = [
            "uid": context.uid,
            "token": context.tokenAfterUID,
            "device": "android",
            "deviceId": context.deviceId,
            "version": "3.4.10",
            "channel": "and-f5",
            "impl": "com.ximalaya.ting.lite"
        ]
        expectedParams["mergeRecords"] = encoded
        let expected = Signatures.history(expectedParams)
        b1Check(call.form["signature"] == expected, "sync-signature")
        b1Check(
            Set(call.form.keys) == Set(["mergeRecords", "signature"]),
            "sync-form-fields"
        )
        b1Check(
            call.method == "FORM" && call.readOnly
                && call.origin == XmlyOrigin.collector.rawValue
                && call.responseLimit == 8 * 1024 * 1024,
            "sync-request"
        )
    }

    func testSyncUnconfirmed() async throws {
        for point: Any in ["-1", -1, "invalid", NSNull()] {
            let history = try service(FakeHTTPTransport { _, _ in
                ["data": ["syncPoint": point]]
            })
            let track = try Track(rawId: "1", albumId: "7")
            await b1ExpectError("history_unconfirmed", "sync-unconfirmed") {
                try await history.sync(
                    track: track, positionSeconds: 10,
                    startedAtMs: 100, endedAtMs: 200
                )
            }
        }
    }

    func testSyncRejectsInvalidPositionAndBounds() async throws {
        let fake = FakeHTTPTransport { _, _ in ["data": ["syncPoint": 1]] }
        let history = try service(fake)
        let track = try Track(rawId: "1", albumId: "7")
        for position in [Double.nan, Double.infinity, -1, 2_147_483_648] {
            await b1ExpectError("invalid_history", "sync-position-invalid", definitive: true) {
                try await history.sync(
                    track: track, positionSeconds: position,
                    startedAtMs: 100, endedAtMs: 200
                )
            }
        }
        for (started, ended): (Int64, Int64) in [
            (0, 100), (-1, 100), (200, 100), (100, 2_115_354_119_001)
        ] {
            await b1ExpectError("invalid_history", "sync-time-invalid", definitive: true) {
                try await history.sync(
                    track: track, positionSeconds: 1,
                    startedAtMs: started, endedAtMs: ended
                )
            }
        }
        let missingAlbum = try Track(rawId: "1")
        let wrongDirection = try Track(
            rawId: "1", albumId: "7", raw: ["direction": 2]
        )
        for invalidTrack in [missingAlbum, wrongDirection] {
            await b1ExpectError("invalid_history", "sync-track-invalid", definitive: true) {
                try await history.sync(
                    track: invalidTrack, positionSeconds: 1,
                    startedAtMs: 100, endedAtMs: 200
                )
            }
        }
        b1Check(fake.calls.isEmpty, "sync-invalid-no-request")
    }

    func testSyncFractionAndNonNumericDirection() async throws {
        let fake = FakeHTTPTransport { _, _ in ["data": ["syncPoint": 0]] }
        let history = try service(fake)
        let track = try Track(
            rawId: "1", albumId: "7", raw: ["direction": "1"]
        )
        try await history.sync(
            track: track, positionSeconds: 12.9,
            startedAtMs: 100, endedAtMs: 200
        )
        guard let text = fake.calls.first?.form["mergeRecords"],
              let rows = try JSONSerialization.jsonObject(
                  with: Data(text.utf8)
              ) as? [[String: Any]] else {
            XCTFail("sync-fraction-record")
            return
        }
        b1Check(rows.first?["breakSecond"] as? String == "12", "sync-truncate")
        b1Check(
            (rows.first?["direction"] as? NSNumber)?.intValue == 0,
            "sync-direction-default"
        )
    }

    func testSharedClientSerializesWholeWriteOperation() async throws {
        let client = XmlyClientService(
            http: FakeHTTPTransport { _, _ in [:] },
            accountContext: try B1Fixture.context()
        )
        let events = B1WriteEvents()
        let firstEntered = expectation(description: "write-first-entered")
        let secondQueued = expectation(description: "write-second-queued")
        let gate = B1TestSuspension()

        let first = Task {
            try await client.withTrackWrite(number: "1") {
                await events.add(1)
                firstEntered.fulfill()
                await gate.wait()
                await events.add(2)
            }
        }
        await fulfillment(of: [firstEntered], timeout: 2)
        let second = Task {
            secondQueued.fulfill()
            try await client.withTrackWrite(number: "1") {
                await events.add(3)
            }
        }
        await fulfillment(of: [secondQueued], timeout: 2)
        await gate.open()
        do {
            try await first.value
            try await second.value
        } catch {
            XCTFail("write-serialization")
        }
        let result = await events.values
        b1Check(result == [1, 2, 3], "write-serialization-order")
    }
}

private actor B1WriteEvents {
    private(set) var values: [Int] = []

    func add(_ value: Int) {
        values.append(value)
    }
}

private actor B1TestSuspension {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}
