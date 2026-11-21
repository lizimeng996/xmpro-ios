// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import XMPro

final class XmlyWelfareServiceTests: XCTestCase {
    private actor WelfareFakeHTTP: HTTPTransport {
        struct RecordedCall: Sendable {
            let method: String
            let origin: String
            let path: String
            let readOnly: Bool
            let signed: Bool
            let bodyJSON: String?
        }

        private(set) var calls: [RecordedCall] = []
        private var getHandler: @Sendable (String) async throws -> [String: Any]
        private var postHandler: @Sendable (String, [String: Any]) async throws -> [String: Any]

        init(
            getHandler: @escaping @Sendable (String) async throws -> [String: Any] = { _ in ["data": [:]] },
            postHandler: @escaping @Sendable (String, [String: Any]) async throws -> [String: Any] = { _, _ in ["data": ["success": true, "rewardDuration": 600]] }
        ) {
            self.getHandler = getHandler
            self.postHandler = postHandler
        }

        func get(
            origin: String, path: String, query: [String: String],
            credentials: Credentials?, signed: Bool, readOnly: Bool,
            headers: [String: String], responseLimit: Int?
        ) async throws -> [String: Any] {
            calls.append(RecordedCall(
                method: "GET", origin: origin, path: path,
                readOnly: readOnly, signed: signed, bodyJSON: nil
            ))
            return try await getHandler(path)
        }

        func getData(
            origin: String, path: String, query: [String: String],
            credentials: Credentials?, signed: Bool, readOnly: Bool,
            headers: [String: String], responseLimit: Int?
        ) async throws -> Data {
            Data()
        }

        func postJson(
            origin: String, path: String, query: [String: String],
            body: [String: Any], credentials: Credentials?, signed: Bool,
            readOnly: Bool, headers: [String: String], responseLimit: Int?
        ) async throws -> [String: Any] {
            let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            calls.append(RecordedCall(
                method: "POST", origin: origin, path: path,
                readOnly: readOnly, signed: signed, bodyJSON: text
            ))
            return try await postHandler(path, body)
        }

        func postForm(
            origin: String, path: String, query: [String: String],
            form: [String: String], credentials: Credentials?, signed: Bool,
            readOnly: Bool, headers: [String: String], responseLimit: Int?
        ) async throws -> [String: Any] {
            [:]
        }

        func followRedirect(url: String) async -> String { url }
    }

    func testAnonymousQueryAndClaimRequireLogin() async {
        let http = WelfareFakeHTTP()
        let service = XmlyWelfareService(
            http: http, accountContext: nil, clock: B1Fixture.clock()
        )
        await b1ExpectError("login_required", "s5-welfare-anon-query", definitive: true) {
            _ = try await service.queryTasks()
        }
        await b1ExpectError("login_required", "s5-welfare-anon-claim", definitive: true) {
            _ = try await service.claim()
        }
        let calls = await http.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testQueryTasksUsesWelfareOriginAndParsesFields() async throws {
        let http = WelfareFakeHTTP(getHandler: { _ in
            [
                "ret": 0,
                "data": [
                    "taskList": [
                        [
                            "taskId": "vip-1",
                            "title": "每日听时福利",
                            "rewardDuration": 1_800,
                            "status": "available",
                            "canReceive": true,
                            "isSecondPhaseCompleted": true,
                            "bizType": "vip"
                        ],
                        [
                            "taskId": "vip-2",
                            "title": "已领取任务",
                            "rewardDuration": 600,
                            "claimed": true
                        ]
                    ]
                ]
            ]
        })
        let clock = B1Fixture.clock()
        let service = XmlyWelfareService(
            http: http, accountContext: try B1Fixture.context(), clock: clock
        )
        let list = try await service.queryTasks()
        XCTAssertEqual(list.tasks.count, 2)
        XCTAssertEqual(list.tasks[0].id, "vip-1")
        XCTAssertEqual(list.tasks[0].rewardSeconds, 1_800)
        XCTAssertTrue(list.tasks[0].claimable)
        XCTAssertEqual(list.tasks[0].isSecondPhaseCompleted, true)
        XCTAssertEqual(list.tasks[0].extraFields["bizType"], "vip")
        XCTAssertFalse(list.tasks[1].claimable)

        let firstQueryCall = await http.calls.first
        let call = try XCTUnwrap(firstQueryCall)
        XCTAssertEqual(call.origin, XmlyOrigin.welfare.rawValue)
        XCTAssertEqual(call.path, "/lite-earn/ting/welfare/queryVipDurationTask/ts-\(clock.now())")
        XCTAssertTrue(call.readOnly)
    }

    func testClaimBuildsRewardSignatureWelfareTicketAndSingleNonRetryPost() async throws {
        let clock = B1Fixture.clock()
        let context = try B1Fixture.context()
        let fixedRequestId = "11111111-2222-3333-4444-555555555555"
        let expectedSignature = Signatures.reward(
            requestId: fixedRequestId,
            uid: context.uid,
            timestamp: clock.now(),
            secondPhase: "true"
        )
        let http = WelfareFakeHTTP(postHandler: { _, _ in
            ["ret": 0, "msg": "领取成功", "data": ["success": true, "rewardDuration": 900]]
        })
        let service = XmlyWelfareService(
            http: http,
            accountContext: context,
            clock: clock,
            uuidProvider: { fixedRequestId }
        )
        let task = WelfareTask(
            id: "t1",
            title: "福利",
            rewardSeconds: 900,
            status: "available",
            claimable: true,
            isSecondPhaseCompleted: true,
            extraFields: ["bizType": "daily", "token": "should-be-filtered"]
        )
        let result = try await service.claim(task: task)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.grantedSeconds, 900)
        XCTAssertEqual(result.message, "领取成功")

        let firstClaimCall = await http.calls.first
        let call = try XCTUnwrap(firstClaimCall)
        XCTAssertEqual(call.method, "POST")
        XCTAssertEqual(call.origin, XmlyOrigin.welfare.rawValue)
        XCTAssertEqual(call.path, "/lite-earn/ting/welfare/rewardDuration/ts-\(clock.now())")
        XCTAssertFalse(call.readOnly)

        let bodyData = try XCTUnwrap(call.bodyJSON?.data(using: .utf8))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["requestId"] as? String, fixedRequestId)
        XCTAssertEqual((body["uid"] as? NSNumber)?.int64Value, Int64(context.uid))
        XCTAssertEqual((body["ts"] as? NSNumber)?.int64Value, clock.now())
        XCTAssertEqual(body["signature"] as? String, expectedSignature)
        XCTAssertEqual(body["isSecondPhaseCompleted"] as? Bool, true)
        XCTAssertEqual(body["bizType"] as? String, "daily")
        XCTAssertNil(body["token"])
        let ticket = try XCTUnwrap(body["ticket"] as? String)
        XCTAssertTrue(ticket.hasPrefix("TAC"))
    }

    func testClaimPreservesServerErrorMessageOnBusinessFailure() async throws {
        let http = WelfareFakeHTTP(postHandler: { _, _ in
            ["ret": 0, "msg": "今日领取次数已达上限", "data": ["success": false, "code": 4001]]
        })
        let service = XmlyWelfareService(
            http: http, accountContext: try B1Fixture.context(), clock: B1Fixture.clock()
        )
        let result = try await service.claim()
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "今日领取次数已达上限")
        XCTAssertEqual(result.grantedSeconds, 0)
    }

    func testConcurrentClaimIsDeduplicatedByGate() async throws {
        let http = WelfareFakeHTTP(postHandler: { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return ["ret": 0, "data": ["success": true, "rewardDuration": 600]]
        })
        let service = XmlyWelfareService(
            http: http, accountContext: try B1Fixture.context(), clock: B1Fixture.clock()
        )
        let task = WelfareTask(
            id: "same-task", title: "任务", rewardSeconds: 600,
            status: "available", claimable: true, isSecondPhaseCompleted: nil, extraFields: [:]
        )

        async let first: Result<WelfareClaimResult, Error> = {
            do { return .success(try await service.claim(task: task)) }
            catch { return .failure(error) }
        }()
        try? await Task.sleep(nanoseconds: 10_000_000)
        async let second: Result<WelfareClaimResult, Error> = {
            do { return .success(try await service.claim(task: task)) }
            catch { return .failure(error) }
        }()

        let outcomes = await [first, second]
        let successes = outcomes.filter { if case .success = $0 { return true }; return false }
        let failures = outcomes.filter { if case .failure = $0 { return true }; return false }
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(failures.count, 1)
        let calls = await http.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testAutoClaimStopsWhenPausedOrSufficientOrTargetReached() async throws {
        let clock = B1Fixture.clock()
        let http = WelfareFakeHTTP(
            getHandler: { _ in
                ["ret": 0, "data": ["taskList": [["taskId": "t1", "title": "领听时", "canReceive": true]]]]
            },
            postHandler: { _, _ in
                ["ret": 0, "data": ["success": true, "rewardDuration": 1_800]]
            }
        )
        let service = XmlyWelfareService(
            http: http, accountContext: try B1Fixture.context(), clock: clock
        )

        let pausedReport = await service.autoClaim(paused: true) {
            try Quota(remainingSeconds: 0, newDevice: false, checkedAtMillis: clock.now())
        }
        XCTAssertEqual(pausedReport.stopReason, .rewardPaused)
        XCTAssertEqual(pausedReport.attempts, 0)

        let sufficientReport = await service.autoClaim(lowWaterSeconds: 600, targetSeconds: 3_600) {
            try Quota(remainingSeconds: 1_200, newDevice: false, checkedAtMillis: clock.now())
        }
        XCTAssertEqual(sufficientReport.stopReason, .alreadySufficient)
        XCTAssertEqual(sufficientReport.attempts, 0)

        var step = 0
        let reachedReport = await service.autoClaim(
            lowWaterSeconds: 600, targetSeconds: 3_600, maxAttempts: 5
        ) {
            step += 1
            let remaining = step == 1 ? 300 : (step == 2 ? 2_100 : 3_900)
            return try Quota(remainingSeconds: remaining, newDevice: false, checkedAtMillis: clock.now())
        }
        XCTAssertEqual(reachedReport.stopReason, .targetReached)
        XCTAssertEqual(reachedReport.attempts, 2)
        XCTAssertEqual(reachedReport.succeeded, 2)
        XCTAssertEqual(reachedReport.finalQuota?.remainingSeconds, 3_900)
    }
}
