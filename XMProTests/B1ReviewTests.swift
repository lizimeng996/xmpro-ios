
import Foundation
import XCTest
@testable import XMPro

// 未编译、未运行：当前只读工具无法启动，未能核对仓库内 Fake 与
// AccountContext 构造器。本文件沿用 HTTPTransport 注入 Fake 的模式，
// 将账号构造集中于 makeContext；若现有构造器标签不同，仅适配该处。
// 全部 fixture 为合成数据；凭据与 Cookie 只做布尔断言，避免失败输出原值。
final class B1ReviewTests: XCTestCase {
    private func makeCredentials(_ suffix: String = "a") throws -> Credentials {
        try Credentials(
            token: "910001&synthetic-review-\(suffix)",
            deviceId: "synthetic-review-device-\(suffix)"
        )
    }

    private func makeContext(_ suffix: String = "a") throws -> AccountContext {
        AccountContext(credentials: try makeCredentials(suffix))
    }

    private func anonymous(
        _ handler: @escaping ReviewFakeHTTPTransport.Handler
    ) -> XmlyClientService {
        XmlyClientService(
            http: ReviewFakeHTTPTransport(handler: handler),
            accountContext: nil
        )
    }

    private func assertError(
        _ code: XmlyError.Code,
        definitive: Bool,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("预期抛出业务错误", file: file, line: line)
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, code.rawValue, file: file, line: line)
            XCTAssertEqual(error.definitive, definitive, file: file, line: line)
        } catch {
            XCTFail("错误类型不符", file: file, line: line)
        }
    }

    // B1：对应 Kotlin 的已认证主 App Cookie；不同绑定账号不能串用字段。
    func testMainAppCookieUsesBoundAccountAndAnonymousReturnsNil() throws {
        let transport = ReviewFakeHTTPTransport { _ in [:] }
        for suffix in ["a", "b"] {
            let credentials = try makeCredentials(suffix)
            let client = XmlyClientService(
                http: transport, accountContext: try makeContext(suffix)
            )
            let cookie = client.mainAppCookie()
            XCTAssertTrue(cookie != nil)
            let expected = "1&_token=\(credentials.token); "
                + "1&_device=android&\(credentials.deviceId)&9.5.1;"
                + "channel=and-d10; impl=com.ximalaya.ting.android; appid=1463"
            XCTAssertTrue(cookie == expected, "已认证 Cookie 字段不符")
            XCTAssertTrue(cookie?.contains("1&_token=\(credentials.token);") == true)
            XCTAssertTrue(
                cookie?.contains("1&_device=android&\(credentials.deviceId)&9.5.1;")
                    == true
            )
            XCTAssertTrue(cookie?.contains("channel=and-d10;") == true)
            XCTAssertTrue(cookie?.contains("impl=com.ximalaya.ting.android;") == true)
            XCTAssertTrue(cookie?.hasSuffix("appid=1463") == true)
        }
        let anonymous = XmlyClientService(http: transport, accountContext: nil)
        XCTAssertTrue(anonymous.mainAppCookie() == nil)
    }

    // M1：Kotlin 为同步实现；Swift 等待者取消必须在持有者释放前完成。
    func testCancelledWaiterExitsWhileHolderRemainsSuspended() async throws {
        let client = anonymous { _ in [:] }
        let hold = ReviewSignal()
        let holderEntered = expectation(description: "持有者进入")
        let waiterStarted = expectation(description: "第二个等待者开始")
        let waiterCancelled = expectation(description: "第二个等待者取消完成")
        let thirdStarted = expectation(description: "第三个等待者开始")
        let thirdEntered = expectation(description: "第三个等待者进入")
        let cancelledOperation = ReviewCounter()
        let thirdOperation = ReviewCounter()

        let holder = Task {
            try await client.withTrackWrite(number: "991001") {
                holderEntered.fulfill()
                await hold.wait()
            }
        }
        await fulfillment(of: [holderEntered], timeout: 2)

        let second = Task {
            waiterStarted.fulfill()
            do {
                try await client.withTrackWrite(number: "991001") {
                    cancelledOperation.increment()
                }
                XCTFail("取消等待者不应成功")
            } catch is CancellationError {
                waiterCancelled.fulfill()
            } catch {
                XCTFail("取消错误类型不符")
            }
        }
        await fulfillment(of: [waiterStarted], timeout: 2)
        // 给 acquire 注册 continuation 的执行机会；持有者由信号明确阻塞。
        try await Task.sleep(nanoseconds: 50_000_000)
        second.cancel()
        await fulfillment(of: [waiterCancelled], timeout: 2)

        let third = Task {
            thirdStarted.fulfill()
            try await client.withTrackWrite(number: "xmly:991001") {
                thirdOperation.increment()
                thirdEntered.fulfill()
            }
        }
        await fulfillment(of: [thirdStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(cancelledOperation.value, 0)
        XCTAssertEqual(thirdOperation.value, 0)

        await hold.open()
        await fulfillment(of: [thirdEntered], timeout: 2)
        try await holder.value
        await second.value
        try await third.value
        XCTAssertEqual(cancelledOperation.value, 0)
        XCTAssertEqual(thirdOperation.value, 1)
    }

    // M1：取消先于 continuation 注册时也必须退出，不能执行 operation。
    func testAlreadyCancelledTaskDoesNotExecuteWriteOperation() async throws {
        let client = anonymous { _ in [:] }
        let start = ReviewSignal()
        let calls = ReviewCounter()
        let finished = expectation(description: "预取消任务退出")
        let task = Task {
            await start.wait()
            do {
                try await client.withTrackWrite(number: "991002") {
                    calls.increment()
                }
                XCTFail("预取消任务不应成功")
            } catch is CancellationError {
                finished.fulfill()
            } catch {
                XCTFail("取消错误类型不符")
            }
        }
        task.cancel()
        await start.open()
        await fulfillment(of: [finished], timeout: 2)
        await task.value
        XCTAssertEqual(calls.value, 0)

        // 预取消获取不能占住门闩。
        try await client.withTrackWrite(number: "991002") {
            calls.increment()
        }
        XCTAssertEqual(calls.value, 1)
    }

    // M1：对应 Swift 加严的门闩契约，持有者抛错仍必须交接。
    func testThrowingHolderReleasesGateToSuccessor() async throws {
        let client = anonymous { _ in [:] }
        let hold = ReviewSignal()
        let entered = expectation(description: "抛错持有者进入")
        let successorStarted = expectation(description: "后继开始")
        let successorEntered = expectation(description: "后继进入")
        let holder = Task {
            do {
                try await client.withTrackWrite(number: "991003") {
                    entered.fulfill()
                    await hold.wait()
                    throw ReviewFailure.synthetic
                }
                XCTFail("持有者应抛错")
            } catch ReviewFailure.synthetic {
            } catch {
                XCTFail("持有者错误类型不符")
            }
        }
        await fulfillment(of: [entered], timeout: 2)

        let successor = Task {
            successorStarted.fulfill()
            try await client.withTrackWrite(number: "991003") {
                successorEntered.fulfill()
            }
        }
        await fulfillment(of: [successorStarted], timeout: 2)
        await hold.open()
        await fulfillment(of: [successorEntered], timeout: 2)
        await holder.value
        try await successor.value
    }

    // M1：Kotlin 普通详情错误降级为空；Swift CancellationError 必须传播。
    func testAlbumDetailPropagatesCancellationButDegradesOrdinaryFailure() async {
        let cancelled = anonymous { _ in throw CancellationError() }
        do {
            _ = try await cancelled.albumDetail(album: "77")
            XCTFail("详情取消不得降级")
        } catch is CancellationError {
        } catch {
            XCTFail("详情取消错误类型不符")
        }

        let failed = anonymous { _ in throw ReviewFailure.synthetic }
        do {
            let detail = try await failed.albumDetail(album: "77")
            XCTAssertTrue(detail.isEmpty)
        } catch {
            XCTFail("普通详情失败应降级")
        }
    }

    // M1：album 调用链不能在详情取消之后继续成功返回。
    func testAlbumPropagatesDetailCancellation() async {
        let client = anonymous { request in
            if request.path == "/mobile-album/album/detail" {
                throw CancellationError()
            }
            return ["data": ["totalCount": 0, "list": [Any]()]]
        }
        do {
            _ = try await client.album(albumId: "77")
            XCTFail("专辑请求应传播详情取消")
        } catch is CancellationError {
        } catch {
            XCTFail("专辑取消错误类型不符")
        }
    }

    // M1：模拟 followRedirect 取消后仍返回当前 URL 的传输层契约。
    func testResolveChecksCancellationAfterRedirectReturns() async {
        let entered = expectation(description: "进入重定向")
        let hold = ReviewSignal()
        let transport = ReviewFakeHTTPTransport(
            handler: { _ in
                [
                    "trackId": 123,
                    "isPaid": false,
                    "playUrl64": "https://mobile.ximalaya.com/synthetic-audio"
                ]
            },
            redirect: { url in
                entered.fulfill()
                await hold.wait()
                return url
            }
        )
        let client = XmlyClientService(http: transport, accountContext: nil)
        let task = Task {
            do {
                _ = try await client.resolve(number: "123")
                XCTFail("重定向取消后不应返回音频")
            } catch is CancellationError {
            } catch {
                XCTFail("重定向取消错误类型不符")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await hold.open()
        await task.value
    }

    // M2：Kotlin 无门闩；验证 Swift 同账号两个 client 的 sync 串行。
    func testSameAccountClientsSerializeHistorySync() async throws {
        let context = try makeContext("shared-gate")
        let firstEntered = expectation(description: "第一个网络请求进入")
        let secondStarted = expectation(description: "第二个 sync 开始")
        let secondEntered = expectation(description: "第二个网络请求进入")
        let releaseFirst = ReviewSignal()
        let firstCompleted = ReviewCounter()
        let secondCalls = ReviewCounter()

        let firstHTTP = ReviewFakeHTTPTransport { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/nyx/v1/history/merge/android")
            firstEntered.fulfill()
            await releaseFirst.wait()
            firstCompleted.increment()
            return ["data": ["syncPoint": "1"]]
        }
        let secondHTTP = ReviewFakeHTTPTransport { request in
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.path, "/nyx/v1/history/merge/android")
            XCTAssertEqual(firstCompleted.value, 1)
            secondCalls.increment()
            secondEntered.fulfill()
            return ["data": ["syncPoint": "2"]]
        }
        let firstHistory = XmlyHistoryService(client: XmlyClientService(
            http: firstHTTP, accountContext: context
        ))
        let secondHistory = XmlyHistoryService(client: XmlyClientService(
            http: secondHTTP, accountContext: context
        ))
        let track = try Track(rawId: "123", albumId: "77", duration: 100)

        let first = Task {
            try await firstHistory.sync(
                track: track, positionSeconds: 10,
                startedAtMs: 1_000, endedAtMs: 2_000
            )
        }
        await fulfillment(of: [firstEntered], timeout: 2)

        let second = Task {
            secondStarted.fulfill()
            try await secondHistory.sync(
                track: track, positionSeconds: 20,
                startedAtMs: 2_000, endedAtMs: 3_000
            )
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(secondCalls.value, 0)

        await releaseFirst.open()
        await fulfillment(of: [secondEntered], timeout: 2)
        try await first.value
        try await second.value
        XCTAssertEqual(secondCalls.value, 1)
    }

    // M3：Kotlin 头部 JSONObject.NULL 经 toString 进入 invalid_id。
    func testExplicitNullAlbumHeaderIsInvalidIDAtBothLocations() async {
        for location in ["album", "data"] {
            let client = anonymous { _ in
                var data: [String: Any] = ["totalCount": 0, "list": [Any]()]
                var payload: [String: Any] = [:]
                if location == "album" {
                    payload["album"] = ["albumId": NSNull()]
                } else {
                    data["albumId"] = NSNull()
                }
                payload["data"] = data
                return payload
            }
            await assertError(.invalidId, definitive: true) {
                _ = try await client.album(albumId: "77")
            }
        }
    }

    // M3：Kotlin 缺失头部字段跳过，声音行 toPlainMap 的 null 也跳过。
    func testMissingHeaderIDAndNullRowAlbumIDAreAccepted() async throws {
        let client = anonymous { request in
            if request.path == "/mobile-album/album/detail" { return [:] }
            return [
                "album": ["title": "合成专辑"],
                "data": [
                    "totalCount": 1,
                    "list": [[
                        "trackId": 123,
                        "albumId": NSNull(),
                        "album_id": NSNull(),
                        "title": "合成声音"
                    ]]
                ]
            ]
        }
        let result = try await client.album(albumId: "77")
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.number, "123")
        XCTAssertEqual(result.tracks.first?.albumKey, "77")
    }

    // M4：对应 Kotlin trackId ?: id，只检查被选中的 trackId。
    func testTrackIDTakesPriorityOverConflictingID() async throws {
        let client = anonymous { _ in ["trackId": 123, "id": 456] }
        let track = try await client.track(number: "123")
        XCTAssertEqual(track.number, "123")
    }

    // M4：Kotlin toPlainMap 把 null 转为空，随后回退到 id。
    func testNullTrackIDFallsBackToID() async throws {
        let client = anonymous { _ in ["trackId": NSNull(), "id": 123] }
        let track = try await client.track(number: "123")
        XCTAssertEqual(track.number, "123")
    }

    // M5：对应 Kotlin LinkedHashMap 与稳定时间排序，不能按 track.id 平局排序。
    func testHistoryTiesKeepFirstAppearanceAndProgressUsesFirst() async throws {
        let transport = ReviewFakeHTTPTransport { _ in
            [
                "data": [
                    "listenModels": [
                        Self.historyRow("900", time: 200),
                        Self.historyRow("100", time: 200)
                    ],
                    "hasMore": false
                ]
            ]
        }
        let history = XmlyHistoryService(client: XmlyClientService(
            http: transport, accountContext: try makeContext("history-ties")
        ))
        let records = try await history.records()
        XCTAssertEqual(records.map { $0.track.number }, ["900", "100"])
        let progress = try await history.progress(albumId: "77")
        XCTAssertEqual(progress?.track.number, "900")
    }

    // M5：Kotlin 更新已有键不改变插入位置；跨页更新后仍保留首次序号。
    func testNewerHistoryReplacementPreservesFirstAppearance() async throws {
        let transport = ReviewFakeHTTPTransport { request in
            if request.query["pageId"] == "1" {
                return [
                    "data": [
                        "listenModels": [
                            Self.historyRow("900", time: 100),
                            Self.historyRow("100", time: 200)
                        ],
                        "hasMore": true
                    ]
                ]
            }
            return [
                "data": [
                    "listenModels": [Self.historyRow("900", time: 200)],
                    "hasMore": false
                ]
            ]
        }
        let history = XmlyHistoryService(client: XmlyClientService(
            http: transport, accountContext: try makeContext("history-replace")
        ))
        let records = try await history.records()
        XCTAssertEqual(records.map { $0.track.number }, ["900", "100"])
        XCTAssertEqual(records.map(\.updatedAt), [200, 200])
        let progress = try await history.progress(albumId: "77")
        XCTAssertEqual(progress?.track.number, "900")
    }

    private static func historyRow(_ track: String, time: Int) -> [String: Any] {
        [
            "type": 1, "childId": track, "itemId": "77",
            "length": 100, "breakSecond": 10, "endedAt": time
        ]
    }

    // M6：对应 Kotlin 递归，孙级回复必须保留。
    func testThreeLevelCommentTreeIsPreserved() async throws {
        let client = anonymous { _ in
            [
                "data": [
                    "comments": [[
                        "id": "1", "content": "根",
                        "replies": [[
                            "id": "2", "content": "子",
                            "replies": [["id": "3", "content": "孙"]]
                        ]]
                    ]]
                ]
            ]
        }
        let page = try await client.trackComments(number: "123")
        let root = try XCTUnwrap(page.comments.first)
        let child = try XCTUnwrap(root.replies.first)
        let grandchild = try XCTUnwrap(child.replies.first)
        XCTAssertEqual(grandchild.content, "孙")
        XCTAssertTrue(grandchild.replies.isEmpty)
    }

    // M6：Kotlin 无深度上限；Swift 有意在根计为 1 的第 8 层截断。
    func testDeepCommentTreeStopsAtEightLevels() async throws {
        var tree: [String: Any] = ["content": "第20层"]
        for depth in stride(from: 19, through: 1, by: -1) {
            tree = ["content": "第\(depth)层", "replies": [tree]]
        }
        let fixture = tree
        let client = anonymous { _ in ["data": ["comments": [fixture]]] }
        let page = try await client.trackComments(number: "123")
        var current = try XCTUnwrap(page.comments.first)
        var depth = 1
        while let next = current.replies.first {
            depth += 1
            current = next
        }
        XCTAssertEqual(depth, 8)
        XCTAssertEqual(current.content, "第8层")
        XCTAssertTrue(current.replies.isEmpty)
    }

    // M6：Kotlin 无节点上限；Swift 每棵树最多 512 节点，根节点计入预算。
    func testCommentNodeBudgetIs512PerTree() async throws {
        let replies: [[String: Any]] = (1...600).map {
            ["id": String($0), "content": "合成回复"]
        }
        let client = anonymous { _ in
            [
                "data": [
                    "comments": [
                        ["content": "根一", "replies": replies],
                        ["content": "根二", "replies": replies]
                    ]
                ]
            ]
        }
        let page = try await client.trackComments(number: "123")
        XCTAssertEqual(page.comments.count, 2)
        for root in page.comments {
            XCTAssertEqual(root.replies.count, 511)
            XCTAssertEqual(root.replies.last?.id, "511")
        }
    }

    // Minor：Kotlin Int 无法表示超上界值，Swift 必须在网络请求前拒绝。
    func testDebitRejectsValuesOutsideInt32PositiveRange() async {
        let calls = ReviewCounter()
        let client = anonymous { _ in
            calls.increment()
            return [:]
        }
        for seconds in [0, -1, Int(Int32.max) + 1] {
            await assertError(.invalidDuration, definitive: true) {
                _ = try await client.debit(seconds: seconds)
            }
        }
        XCTAssertEqual(calls.value, 0)
    }

    // Minor：Int32.max 本身仍合法；通过合成 report 响应验证边界。
    func testDebitAcceptsInt32Maximum() async throws {
        let transport = ReviewFakeHTTPTransport { request in
            XCTAssertEqual(request.path, "/lite-mobile/audi/func/v1/report")
            XCTAssertEqual(request.body["duration"] as? String, String(Int32.max))
            XCTAssertFalse(request.readOnly)
            let encrypted = try XmlyCrypto.encrypt(
                "0|\(ServerClock.shared.now())",
                key: XmlyCrypto.durationKey
            )
            return ["data": ["availableListenDuration": encrypted]]
        }
        let client = XmlyClientService(
            http: transport, accountContext: try makeContext("debit")
        )
        let quota = try await client.debit(seconds: Int(Int32.max))
        XCTAssertEqual(quota.remainingSeconds, 0)
    }

    // Minor：对应 Kotlin，非法 totalCount 优先于缺失 list。
    func testAlbumValidatesTotalBeforeMissingList() async {
        let invalidTotal = anonymous { _ in ["data": ["totalCount": "invalid"]] }
        await assertError(.invalidPage, definitive: false) {
            _ = try await invalidTotal.album(albumId: "77")
        }

        let missingTotal = anonymous { _ in ["data": [String: Any]() ] }
        await assertError(.invalidPage, definitive: false) {
            _ = try await missingTotal.album(albumId: "77")
        }

        let validTotal = anonymous { _ in ["data": ["totalCount": 0]] }
        await assertError(.invalidCatalogue, definitive: false) {
            _ = try await validTotal.album(albumId: "77")
        }
    }

    // Minor：Kotlin 对象／数组 ID 的非空文本触发 invalid_id。
    // 搜索直接经过 trackFromApi，避免仅覆盖 trackInfoMap 的前置检查。
    func testSearchRejectsObjectAndArrayTrackIdentifiers() async {
        let invalidValues: [Any] = [["synthetic": 1], [1, 2]]
        for key in ["trackId", "id"] {
            for value in invalidValues {
                let client = anonymous { _ in
                    [
                        "data": [
                            "result": [
                                "response": [
                                    "docs": [[key: value]],
                                    "numFound": 1
                                ]
                            ]
                        ]
                    ]
                }
                await assertError(.invalidId, definitive: true) {
                    _ = try await client.search(query: "合成关键词")
                }
            }
        }
    }

    // Minor／M4：对象型优先字段不能被合法备用 id 覆盖。
    func testTrackRejectsObjectIdentifierInsteadOfMissingTrack() async {
        let client = anonymous { _ in
            ["trackId": ["synthetic": 1], "id": 123]
        }
        await assertError(.invalidId, definitive: true) {
            _ = try await client.track(number: "123")
        }
    }

    // Minor：固定文案按码区分，不包含服务端原文。
    func testErrorsHaveCodeSpecificFixedMessages() {
        XCTAssertEqual(B1JSON.error(.loginRequired).message, "请先登录")
        XCTAssertEqual(
            B1JSON.error(.missingTrack).message,
            "声音信息缺失"
        )
        XCTAssertEqual(
            B1JSON.error(.invalidAuthorization).message,
            "授权声音信息无效"
        )
        XCTAssertNotEqual(
            B1JSON.error(.loginRequired).message,
            B1JSON.error(.insufficientQuota).message
        )
    }

    // N1：对象／数组型专辑编号走 trackFromApi 时同样报 definitive invalid_id。
    func testSearchRejectsObjectAndArrayAlbumIdentifiers() async {
        let invalidValues: [Any] = [["synthetic": 1], [1, 2]]
        for key in ["albumId", "album_id"] {
            for value in invalidValues {
                let client = anonymous { _ in
                    [
                        "data": [
                            "result": [
                                "response": [
                                    "docs": [["trackId": "123", key: value]],
                                    "numFound": 1
                                ]
                            ]
                        ]
                    ]
                }
                await assertError(.invalidId, definitive: true) {
                    _ = try await client.search(query: "合成关键词")
                }
            }
        }
    }

    // N1：缺专辑编号仍可解析，专辑编号为空串。
    func testSearchRowWithoutAlbumIDStillParses() async throws {
        let client = anonymous { _ in
            [
                "data": [
                    "result": [
                        "response": [
                            "docs": [["trackId": "123", "title": "合成声音"]],
                            "numFound": 1
                        ]
                    ]
                ]
            ]
        }
        let page = try await client.search(query: "合成关键词")
        XCTAssertEqual(page.tracks.count, 1)
        XCTAssertEqual(page.tracks.first?.albumId, "")
    }

    // 复审建议 2：不同账号的同声音写回不互斥。
    func testDifferentAccountsSyncInParallel() async throws {
        let firstEntered = expectation(description: "账号 A 网络请求进入")
        let secondEntered = expectation(description: "账号 B 网络请求进入")
        let releaseFirst = ReviewSignal()
        let firstHTTP = ReviewFakeHTTPTransport { _ in
            firstEntered.fulfill()
            await releaseFirst.wait()
            return ["data": ["syncPoint": "2"]]
        }
        let secondHTTP = ReviewFakeHTTPTransport { _ in
            secondEntered.fulfill()
            return ["data": ["syncPoint": "2"]]
        }
        let track = try Track(rawId: "123", albumId: "77", duration: 100)
        let firstHistory = XmlyHistoryService(client: XmlyClientService(
            http: firstHTTP, accountContext: try makeContext("parallel-a")
        ))
        let secondHistory = XmlyHistoryService(client: XmlyClientService(
            http: secondHTTP, accountContext: try makeContext("parallel-b")
        ))
        let first = Task {
            try await firstHistory.sync(
                track: track, positionSeconds: 10,
                startedAtMs: 1_000, endedAtMs: 2_000
            )
        }
        // 先确认 A 已持有门闩，再启动 B；若门闩被错误共享，
        // B 的请求会被 A 阻塞，2 秒内进不来。
        await fulfillment(of: [firstEntered], timeout: 2)
        let second = Task {
            try await secondHistory.sync(
                track: track, positionSeconds: 10,
                startedAtMs: 1_000, endedAtMs: 2_000
            )
        }
        await fulfillment(of: [secondEntered], timeout: 2)
        await releaseFirst.open()
        try await first.value
        try await second.value
    }

    // 复审建议 4：第 50 页仍 hasMore 时报 history_limit。
    func testHistoryStopsAtFiftyPages() async throws {
        let calls = ReviewCounter()
        let fake = ReviewFakeHTTPTransport { request in
            calls.increment()
            let page = Int(request.query["pageId"] ?? "0") ?? 0
            return ["data": [
                "listenModels": [[
                    "type": 1, "deleteTime": 0, "childId": 9_000 + page,
                    "itemId": 77, "childTitle": "合成声音", "itemTitle": "合成专辑",
                    "itemCoverUrl": "//fixture.xmcdn.com/cover",
                    "length": 100, "breakSecond": 20, "endedAt": 1_000 + page
                ]],
                "hasMore": true
            ]]
        }
        let history = XmlyHistoryService(client: XmlyClientService(
            http: fake, accountContext: try makeContext("fifty")
        ))
        await assertError(.historyLimit, definitive: false) {
            _ = try await history.records()
        }
        XCTAssertEqual(calls.value, 50)
    }

    // 复审建议 5：评论递归在第 8 层截断。
    func testCommentRecursionStopsAtDepthEight() async throws {
        func nested(_ depth: Int) -> [String: Any] {
            var node: [String: Any] = [
                "id": depth, "uid": "1", "content": "第 \(depth) 层",
                "createAt": "", "likes": 0, "replyCount": 0
            ]
            if depth < 10 {
                node["replies"] = [nested(depth + 1)]
            }
            return node
        }
        let client = anonymous { _ in
            ["data": [
                "comments": [nested(1)], "currentPage": 1,
                "totalPage": 1, "totalComment": 1
            ]]
        }
        let page = try await client.trackComments(number: "1")
        var depth = 0
        var current = page.comments.first
        while let comment = current {
            depth += 1
            current = comment.replies.first
        }
        XCTAssertEqual(depth, 8)
    }

    // 复审建议 5：每棵根评论最多访问 512 个对象节点。
    func testCommentNodeBudgetCapsWideTree() async throws {
        var replies: [[String: Any]] = []
        for index in 1...600 {
            replies.append([
                "id": index, "uid": "1", "content": "回复 \(index)",
                "createAt": "", "likes": 0, "replyCount": 0
            ])
        }
        let root: [String: Any] = [
            "id": 0, "uid": "1", "content": "根评论",
            "createAt": "", "likes": 0, "replyCount": 600, "replies": replies
        ]
        let client = anonymous { _ in
            ["data": [
                "comments": [root], "currentPage": 1,
                "totalPage": 1, "totalComment": 1
            ]]
        }
        let page = try await client.trackComments(number: "1")
        XCTAssertEqual(page.comments.count, 1)
        // 根节点占 1 个预算，剩余 511 个给回复。
        XCTAssertEqual(page.comments.first?.replies.count, 511)
        XCTAssertEqual(page.comments.first?.replies.last?.id, "511")
    }
}

private enum ReviewFailure: Error {
    case synthetic
}

// 沿用 FakeHTTPTransport 注入模式；请求快照不存储凭据或签名字段。
// 独立命名避免与现有测试 Fake 重名。
private final class ReviewFakeHTTPTransport: HTTPTransport {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let body: [String: Any]
        let readOnly: Bool
    }

    typealias Handler = (Request) async throws -> [String: Any]
    private let handler: Handler
    private let redirect: (String) async -> String

    init(
        handler: @escaping Handler,
        redirect: @escaping (String) async -> String = { $0 }
    ) {
        self.handler = handler
        self.redirect = redirect
    }

    func get(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try await handler(Request(
            method: "GET", path: path, query: query,
            body: [:], readOnly: readOnly
        ))
    }

    func getData(
        origin: String,
        path: String,
        query: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> Data {
        let object = try await get(
            origin: origin, path: path, query: query,
            credentials: credentials, signed: signed, readOnly: readOnly,
            headers: headers, responseLimit: responseLimit
        )
        return try JSONSerialization.data(withJSONObject: object)
    }

    func postForm(
        origin: String,
        path: String,
        query: [String: String],
        form: [String: String],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        try await handler(Request(
            method: "POST", path: path, query: query,
            body: [:], readOnly: readOnly
        ))
    }

    func postJson(
        origin: String,
        path: String,
        query: [String: String],
        body: [String: Any],
        credentials: Credentials?,
        signed: Bool,
        readOnly: Bool,
        headers: [String: String],
        responseLimit: Int?
    ) async throws -> [String: Any] {
        // 只保留本组断言需要的非敏感合成参数。
        var safeBody: [String: Any] = [:]
        if let duration = body["duration"] { safeBody["duration"] = duration }
        return try await handler(Request(
            method: "POST", path: path, query: query,
            body: safeBody, readOnly: readOnly
        ))
    }

    func followRedirect(url: String) async -> String {
        await redirect(url)
    }
}

// 测试信号不响应取消，便于模拟持有者挂起或辅助调用吞掉取消。
// open 幂等，支持先打开再等待。
private actor ReviewSignal {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

// 同步锁保护测试计数；锁不跨 await。
private final class ReviewCounter {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
    }
}
