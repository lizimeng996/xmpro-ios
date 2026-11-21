// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct WelfareTask: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let rewardSeconds: Int
    let status: String
    let claimable: Bool
    let isSecondPhaseCompleted: Bool?
    let extraFields: [String: String]
}

struct WelfareTaskList: Equatable, Sendable {
    let tasks: [WelfareTask]
    let checkedAtMs: Int64
}

struct WelfareClaimResult: Equatable, Sendable {
    let requestId: String
    let success: Bool
    let message: String
    let grantedSeconds: Int
    let claimedAtMs: Int64
    let isSecondPhaseCompleted: Bool?
}

enum WelfareAutoClaimStopReason: String, Equatable, Sendable {
    case targetReached = "target_reached"
    case alreadySufficient = "already_sufficient"
    case rewardPaused = "reward_paused"
    case rejected = "rejected"
    case maxAttemptsReached = "max_attempts_reached"
    case failed = "failed"
}

struct WelfareAutoClaimReport: Sendable {
    let attempts: Int
    let succeeded: Int
    let stopReason: WelfareAutoClaimStopReason
    let finalQuota: Quota?
    let results: [WelfareClaimResult]
}

private actor WelfareClaimGate {
    private var inFlight: Set<String> = []

    func enter(_ key: String) -> Bool {
        inFlight.insert(key).inserted
    }

    func leave(_ key: String) {
        inFlight.remove(key)
    }
}

final class XmlyWelfareService {
    static let defaultLowWaterSeconds = 600
    static let defaultTargetSeconds = 3_600
    static let defaultMaxAutoAttempts = 5

    private static let reservedBodyKeys: Set<String> = [
        "requestId", "uid", "ts", "signature", "ticket",
        "isSecondPhaseCompleted"
    ]

    private let http: any HTTPTransport
    private let accountContext: AccountContext?
    private let clock: ServerClock
    private let uuidProvider: @Sendable () -> String
    private let claimGate = WelfareClaimGate()

    init(
        http: any HTTPTransport,
        accountContext: AccountContext?,
        clock: ServerClock = .shared,
        uuidProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.http = http
        self.accountContext = accountContext
        self.clock = clock
        self.uuidProvider = uuidProvider
    }

    var hasAccount: Bool {
        accountContext != nil
    }

    func queryTasks() async throws -> WelfareTaskList {
        let credentials = try requireCredentials()
        let ts = clock.now()
        let payload = try await http.get(
            origin: XmlyOrigin.welfare.rawValue,
            path: "/lite-earn/ting/welfare/queryVipDurationTask/ts-\(ts)",
            query: [:],
            credentials: credentials,
            signed: false,
            readOnly: true,
            headers: ProtocolConfig.originHeaders(origin: XmlyOrigin.welfare.rawValue),
            responseLimit: nil
        )
        let tasks = parseTasks(from: payload)
        return WelfareTaskList(tasks: tasks, checkedAtMs: ts)
    }

    /// 领取听时福利：非幂等写操作，单次提交不重试，防并发重复领取。
    func claim(task: WelfareTask? = nil) async throws -> WelfareClaimResult {
        let credentials = try requireCredentials()
        guard let numericUid = Int64(credentials.uid) else {
            throw XmlyError.failure(
                code: .invalidId,
                message: "账号 UID 格式无效",
                definitive: true
            )
        }

        let gateKey = "\(credentials.identity):\(task?.id ?? "default")"
        guard await claimGate.enter(gateKey) else {
            throw XmlyError.failure(
                code: .uncertain,
                message: "该福利任务正在领取中，请勿重复提交"
            )
        }

        let requestId = uuidProvider()
        let ts = clock.now()
        let secondPhaseText = task?.isSecondPhaseCompleted.map { $0 ? "true" : "false" }
        let signature = Signatures.reward(
            requestId: requestId,
            uid: credentials.uid,
            timestamp: ts,
            secondPhase: secondPhaseText
        )
        let ticket: String
        do {
            ticket = try XmlyCrypto.freshTicket(
                credentials: credentials,
                attributes: XmlyCrypto.welfareAttributes(for: credentials),
                nowSeconds: ts / 1_000
            )
        } catch {
            await claimGate.leave(gateKey)
            throw error
        }

        var body: [String: Any] = [
            "requestId": requestId,
            "uid": numericUid,
            "ts": ts,
            "signature": signature,
            "ticket": ticket
        ]
        if let completed = task?.isSecondPhaseCompleted {
            body["isSecondPhaseCompleted"] = completed
        }
        if let extra = task?.extraFields {
            for (key, value) in extra where !Self.reservedBodyKeys.contains(key)
                && !StateDocument.secretKeys.contains(key) {
                body[key] = value
            }
        }

        let outcome: WelfareClaimResult
        do {
            let payload = try await http.postJson(
                origin: XmlyOrigin.welfare.rawValue,
                path: "/lite-earn/ting/welfare/rewardDuration/ts-\(ts)",
                query: [:],
                body: body,
                credentials: credentials,
                signed: false,
                readOnly: false,
                headers: ProtocolConfig.originHeaders(origin: XmlyOrigin.welfare.rawValue),
                responseLimit: nil
            )
            outcome = parseClaimResult(
                payload: payload,
                requestId: requestId,
                claimedAtMs: ts,
                secondPhase: task?.isSecondPhaseCompleted
            )
        } catch let error as XmlyError {
            outcome = WelfareClaimResult(
                requestId: requestId,
                success: false,
                message: error.message,
                grantedSeconds: 0,
                claimedAtMs: ts,
                isSecondPhaseCompleted: task?.isSecondPhaseCompleted
            )
        } catch {
            await claimGate.leave(gateKey)
            throw error
        }
        await claimGate.leave(gateKey)
        return outcome
    }

    /// 低水位循环领取：直到达到目标余额、服务端拒绝/失败或达到单轮上限。
    func autoClaim(
        paused: Bool = false,
        lowWaterSeconds: Int = defaultLowWaterSeconds,
        targetSeconds: Int = defaultTargetSeconds,
        maxAttempts: Int = defaultMaxAutoAttempts,
        fetchQuota: () async throws -> Quota
    ) async -> WelfareAutoClaimReport {
        if paused {
            return WelfareAutoClaimReport(
                attempts: 0,
                succeeded: 0,
                stopReason: .rewardPaused,
                finalQuota: nil,
                results: []
            )
        }

        let safeMax = max(1, min(20, maxAttempts))
        let safeLowWater = max(0, lowWaterSeconds)
        let safeTarget = max(safeLowWater, targetSeconds)

        var currentQuota: Quota
        do {
            currentQuota = try await fetchQuota()
        } catch {
            return WelfareAutoClaimReport(
                attempts: 0,
                succeeded: 0,
                stopReason: .failed,
                finalQuota: nil,
                results: []
            )
        }

        if currentQuota.remainingSeconds >= safeLowWater {
            return WelfareAutoClaimReport(
                attempts: 0,
                succeeded: 0,
                stopReason: .alreadySufficient,
                finalQuota: currentQuota,
                results: []
            )
        }

        var results: [WelfareClaimResult] = []
        var succeeded = 0
        var stopReason: WelfareAutoClaimStopReason = .maxAttemptsReached

        for _ in 0..<safeMax {
            if Task.isCancelled {
                stopReason = .failed
                break
            }
            let tasks = (try? await queryTasks())?.tasks ?? []
            let nextTask = tasks.first(where: { $0.claimable }) ?? tasks.first
            do {
                let result = try await claim(task: nextTask)
                results.append(result)
                guard result.success else {
                    stopReason = .rejected
                    break
                }
                succeeded += 1
                if let refreshed = try? await fetchQuota() {
                    currentQuota = refreshed
                    if refreshed.remainingSeconds >= safeTarget {
                        stopReason = .targetReached
                        break
                    }
                }
            } catch {
                stopReason = .failed
                break
            }
        }

        return WelfareAutoClaimReport(
            attempts: results.count,
            succeeded: succeeded,
            stopReason: stopReason,
            finalQuota: currentQuota,
            results: results
        )
    }

    private func requireCredentials() throws -> Credentials {
        guard let accountContext else {
            throw XmlyError.failure(
                code: .loginRequired,
                message: "登录后才能查询或领取听时福利",
                definitive: true
            )
        }
        return try Credentials(
            token: accountContext.uid + "&" + accountContext.tokenAfterUID,
            deviceId: accountContext.deviceId
        )
    }

    private func parseTasks(from payload: [String: Any]) -> [WelfareTask] {
        let data = payload["data"] as? [String: Any] ?? payload
        let rawList: [Any]
        if let list = data["taskList"] as? [Any] {
            rawList = list
        } else if let list = data["tasks"] as? [Any] {
            rawList = list
        } else if let list = data["list"] as? [Any] {
            rawList = list
        } else if let list = payload["data"] as? [Any] {
            rawList = list
        } else if data["taskId"] != nil || data["isSecondPhaseCompleted"] != nil {
            rawList = [data]
        } else {
            rawList = []
        }

        var tasks: [WelfareTask] = []
        for (index, item) in rawList.enumerated() {
            guard let object = item as? [String: Any] else { continue }
            let idText = firstText(object, keys: ["taskId", "id", "taskCode", "code"])
                ?? "welfare-\(index + 1)"
            let title = firstText(object, keys: ["title", "taskName", "name", "desc"])
                ?? "听时福利任务"
            let rewardSeconds = xmlyOptInt(
                object["rewardDuration"] ?? object["duration"] ?? object["rewardSeconds"]
            ) ?? 0
            let status = firstText(object, keys: ["status", "taskStatus", "state"]) ?? "available"
            let completedFlag = B1JSON.boolean(object["isSecondPhaseCompleted"])
            let claimedFlag = B1JSON.boolean(object["claimed"])
                ?? B1JSON.boolean(object["isReceived"])
                ?? (status.lowercased() == "claimed" || status.lowercased() == "finished")
            let claimable = B1JSON.boolean(object["canReceive"])
                ?? B1JSON.boolean(object["claimable"])
                ?? !claimedFlag

            var extra: [String: String] = [:]
            for key in ["taskId", "taskCode", "activityId", "bizType", "scene"] {
                if let text = firstText(object, keys: [key]) {
                    extra[key] = text
                }
            }

            tasks.append(WelfareTask(
                id: idText,
                title: title,
                rewardSeconds: max(0, rewardSeconds),
                status: status,
                claimable: claimable,
                isSecondPhaseCompleted: completedFlag,
                extraFields: extra
            ))
        }
        return tasks
    }

    private func parseClaimResult(
        payload: [String: Any],
        requestId: String,
        claimedAtMs: Int64,
        secondPhase: Bool?
    ) -> WelfareClaimResult {
        let data = payload["data"] as? [String: Any] ?? [:]
        let serverMsg = firstText(payload, keys: ["msg", "message"])
            ?? firstText(data, keys: ["msg", "message"])
        let dataCode = xmlyOptInt(data["code"])
        let explicitlyFailed = (B1JSON.boolean(data["success"]) == false)
            || (dataCode != nil && dataCode != 0 && dataCode != 200)

        let granted = max(
            0,
            xmlyOptInt(
                data["rewardDuration"]
                    ?? data["grantedDuration"]
                    ?? data["duration"]
                    ?? payload["duration"]
            ) ?? 0
        )

        if explicitlyFailed {
            return WelfareClaimResult(
                requestId: requestId,
                success: false,
                message: serverMsg ?? "福利领取未成功",
                grantedSeconds: 0,
                claimedAtMs: claimedAtMs,
                isSecondPhaseCompleted: secondPhase
            )
        }
        return WelfareClaimResult(
            requestId: requestId,
            success: true,
            message: serverMsg ?? "领取成功",
            grantedSeconds: granted,
            claimedAtMs: claimedAtMs,
            isSecondPhaseCompleted: secondPhase
        )
    }

    private func firstText(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            let text = B1JSON.text(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }
}
