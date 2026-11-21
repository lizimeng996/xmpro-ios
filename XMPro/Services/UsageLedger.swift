// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum UsageReportStatus: String, Equatable, Sendable {
    case succeeded
    case failed
}

struct UsageReportRecord: Equatable, Sendable, Identifiable {
    let id: String
    let seconds: Int
    let status: UsageReportStatus
    let message: String
    let remainingAfter: Int?
    let timestampMs: Int64

    func toJson() -> [String: Any] {
        var json: [String: Any] = [
            "id": id,
            "seconds": seconds,
            "status": status.rawValue,
            "message": message,
            "timestampMs": timestampMs
        ]
        if let remainingAfter {
            json["remainingAfter"] = remainingAfter
        }
        return json
    }

    static func fromJson(_ json: [String: Any]) -> UsageReportRecord? {
        guard let id = json["id"] as? String, !id.isEmpty,
              let statusText = json["status"] as? String,
              let status = UsageReportStatus(rawValue: statusText) else {
            return nil
        }
        let seconds = max(0, xmlyOptInt(json["seconds"]) ?? 0)
        let message = (json["message"] as? String) ?? ""
        let remainingAfter = xmlyOptInt(json["remainingAfter"])
        let timestampMs = xmlyJsonLong(json["timestampMs"], default: 0)
        return UsageReportRecord(
            id: id,
            seconds: seconds,
            status: status,
            message: message,
            remainingAfter: remainingAfter,
            timestampMs: timestampMs
        )
    }
}

struct AccountUsageLedger: Equatable, Sendable {
    let identity: String
    var accumulatedSeconds: Int
    var pendingSeconds: Int
    var totalReportedSeconds: Int
    var lastReportedAtMs: Int64?
    var records: [UsageReportRecord]

    init(
        identity: String,
        accumulatedSeconds: Int = 0,
        pendingSeconds: Int = 0,
        totalReportedSeconds: Int = 0,
        lastReportedAtMs: Int64? = nil,
        records: [UsageReportRecord] = []
    ) {
        self.identity = identity
        self.accumulatedSeconds = max(0, accumulatedSeconds)
        self.pendingSeconds = max(0, pendingSeconds)
        self.totalReportedSeconds = max(0, totalReportedSeconds)
        self.lastReportedAtMs = lastReportedAtMs
        self.records = records
    }

    func toJson() -> [String: Any] {
        var json: [String: Any] = [
            "accumulatedSeconds": accumulatedSeconds,
            "pendingSeconds": pendingSeconds,
            "totalReportedSeconds": totalReportedSeconds,
            "records": records.map { $0.toJson() }
        ]
        if let lastReportedAtMs {
            json["lastReportedAtMs"] = lastReportedAtMs
        }
        return json
    }

    static func fromJson(identity: String, _ json: [String: Any]) -> AccountUsageLedger {
        let accumulated = max(0, xmlyOptInt(json["accumulatedSeconds"]) ?? 0)
        let pending = max(0, xmlyOptInt(json["pendingSeconds"]) ?? 0)
        let reported = max(0, xmlyOptInt(json["totalReportedSeconds"]) ?? 0)
        let lastAt: Int64? = json["lastReportedAtMs"] != nil
            ? xmlyJsonLong(json["lastReportedAtMs"], default: 0)
            : nil
        let rawRecords = json["records"] as? [Any] ?? []
        let records = rawRecords.compactMap { ($0 as? [String: Any]).flatMap(UsageReportRecord.fromJson) }
        return AccountUsageLedger(
            identity: identity,
            accumulatedSeconds: accumulated,
            pendingSeconds: pending,
            totalReportedSeconds: reported,
            lastReportedAtMs: lastAt,
            records: records
        )
    }
}

/// 听时账本：按账号 identity 隔离维护真实播放计时、待上报秒数与上报记录；
/// 服务端听时额度按设备维度归属，不随账号切换清零。
actor UsageLedger {
    private struct ActiveTimer {
        var startedAtMs: Int64?
        var requiresReward: Bool
        var remainderMs: Int64
    }

    private let repository: StateRepository
    private let nowMs: @Sendable () -> Int64
    private let maxRecordHistory: Int
    private let uuidProvider: @Sendable () -> String

    private var timers: [String: ActiveTimer] = [:]
    private var reporting: Set<String> = []
    private var deviceQuotaCache: Quota?

    init(
        repository: StateRepository,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        maxRecordHistory: Int = 50,
        uuidProvider: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.repository = repository
        self.nowMs = nowMs
        self.maxRecordHistory = max(1, maxRecordHistory)
        self.uuidProvider = uuidProvider
    }

    /// 播放状态变化：仅在确认处于播放态时按真实墙钟累计，暂停／缓冲／结束立即结算并停止计时。
    func onPlaybackStateChanged(
        identity: String,
        isPlaying: Bool,
        requiresReward: Bool
    ) async {
        guard !identity.isEmpty else { return }
        let now = nowMs()
        var timer = timers[identity] ?? ActiveTimer(
            startedAtMs: nil, requiresReward: requiresReward, remainderMs: 0
        )

        if let started = timer.startedAtMs {
            let elapsed = max(0, now - started)
            timer.remainderMs += elapsed
            let wholeSeconds = Int(timer.remainderMs / 1_000)
            timer.remainderMs %= 1_000
            let shouldDebit = timer.requiresReward
            if wholeSeconds > 0 {
                await addSeconds(
                    identity: identity,
                    seconds: wholeSeconds,
                    requiresReward: shouldDebit
                )
            }
        }

        if isPlaying {
            timer.startedAtMs = now
            timer.requiresReward = requiresReward
        } else {
            timer.startedAtMs = nil
            timer.requiresReward = requiresReward
        }
        timers[identity] = timer
    }

    /// 拖动进度条：只结算拖动前真实听过的墙钟时间，不把媒体进度跳跃计入听时。
    func onSeek(identity: String) async {
        guard !identity.isEmpty, var timer = timers[identity], let started = timer.startedAtMs else {
            return
        }
        let now = nowMs()
        let elapsed = max(0, now - started)
        timer.remainderMs += elapsed
        let wholeSeconds = Int(timer.remainderMs / 1_000)
        timer.remainderMs %= 1_000
        timer.startedAtMs = now
        timers[identity] = timer
        if wholeSeconds > 0 {
            await addSeconds(
                identity: identity,
                seconds: wholeSeconds,
                requiresReward: timer.requiresReward
            )
        }
    }

    /// 倍速变化不影响真实墙钟听时累计（保留显式入口便于调用方声明意图）。
    func onSpeedChanged(identity: String, speed: Double) async {
        _ = (identity, speed)
    }

    /// 结算当前正在播放的墙钟累计但不中断播放。
    func flushTick(identity: String) async {
        guard !identity.isEmpty, var timer = timers[identity], let started = timer.startedAtMs else {
            return
        }
        let now = nowMs()
        let elapsed = max(0, now - started)
        timer.remainderMs += elapsed
        let wholeSeconds = Int(timer.remainderMs / 1_000)
        timer.remainderMs %= 1_000
        timer.startedAtMs = now
        timers[identity] = timer
        if wholeSeconds > 0 {
            await addSeconds(
                identity: identity,
                seconds: wholeSeconds,
                requiresReward: timer.requiresReward
            )
        }
    }

    func snapshot(identity: String) async -> AccountUsageLedger {
        let document = await repository.state()
        let account = document.accounts[identity] as? [String: Any] ?? [:]
        let rawLedger = account["ledger"] as? [String: Any] ?? [:]
        return AccountUsageLedger.fromJson(identity: identity, rawLedger)
    }

    func cachedDeviceQuota() -> Quota? {
        deviceQuotaCache
    }

    /// 刷新服务端设备听时额度，同时更新设备级缓存与当前账号状态树中的 quota 字段。
    @discardableResult
    func refreshQuota(
        identity: String,
        client: XmlyClientService
    ) async throws -> Quota {
        let quota = try await client.quota()
        deviceQuotaCache = quota
        await persistQuota(identity: identity, quota: quota)
        return quota
    }

    /// 上报待扣减听时；非幂等写操作，单次提交、防并发重入，失败保留待上报余额并记入失败记录。
    @discardableResult
    func reportPending(
        identity: String,
        client: XmlyClientService
    ) async -> UsageReportRecord? {
        guard !identity.isEmpty else { return nil }
        await flushTick(identity: identity)

        guard reporting.insert(identity).inserted else { return nil }
        defer { reporting.remove(identity) }

        let current = await snapshot(identity: identity)
        guard current.pendingSeconds > 0 else { return nil }
        let secondsToReport = current.pendingSeconds
        let timestamp = nowMs()

        do {
            let quota = try await client.debit(seconds: secondsToReport)
            deviceQuotaCache = quota
            let record = UsageReportRecord(
                id: uuidProvider(),
                seconds: secondsToReport,
                status: .succeeded,
                message: "上报成功",
                remainingAfter: quota.remainingSeconds,
                timestampMs: timestamp
            )
            await commitReportOutcome(
                identity: identity,
                reportedSeconds: secondsToReport,
                quota: quota,
                record: record
            )
            return record
        } catch let error as XmlyError {
            let record = UsageReportRecord(
                id: uuidProvider(),
                seconds: secondsToReport,
                status: .failed,
                message: error.message,
                remainingAfter: nil,
                timestampMs: timestamp
            )
            await commitReportOutcome(
                identity: identity,
                reportedSeconds: 0,
                quota: nil,
                record: record
            )
            return record
        } catch {
            let record = UsageReportRecord(
                id: uuidProvider(),
                seconds: secondsToReport,
                status: .failed,
                message: "听时上报失败，已保留待上报记录",
                remainingAfter: nil,
                timestampMs: timestamp
            )
            await commitReportOutcome(
                identity: identity,
                reportedSeconds: 0,
                quota: nil,
                record: record
            )
            return record
        }
    }

    /// 低水位触发自动领取：读取账号 rewardPaused 状态并复用设备额度查询。
    func coordinateAutoClaim(
        identity: String,
        client: XmlyClientService,
        welfare: XmlyWelfareService,
        lowWaterSeconds: Int = XmlyWelfareService.defaultLowWaterSeconds,
        targetSeconds: Int = XmlyWelfareService.defaultTargetSeconds,
        maxAttempts: Int = XmlyWelfareService.defaultMaxAutoAttempts
    ) async -> WelfareAutoClaimReport {
        let document = await repository.state()
        let account = document.accounts[identity] as? [String: Any] ?? [:]
        let paused = account["rewardPaused"] as? Bool ?? false
        return await welfare.autoClaim(
            paused: paused,
            lowWaterSeconds: lowWaterSeconds,
            targetSeconds: targetSeconds,
            maxAttempts: maxAttempts
        ) {
            try await self.refreshQuota(identity: identity, client: client)
        }
    }

    private func addSeconds(
        identity: String,
        seconds: Int,
        requiresReward: Bool
    ) async {
        guard seconds > 0 else { return }
        _ = try? await repository.transaction { document in
            var accounts = document.accounts
            var account = accounts[identity] as? [String: Any] ?? [:]
            let rawLedger = account["ledger"] as? [String: Any] ?? [:]
            var ledger = AccountUsageLedger.fromJson(identity: identity, rawLedger)
            ledger.accumulatedSeconds += seconds
            if requiresReward {
                ledger.pendingSeconds += seconds
            }
            var mergedLedger = rawLedger
            for (key, value) in ledger.toJson() {
                mergedLedger[key] = value
            }
            account["ledger"] = mergedLedger
            accounts[identity] = account
            try document.setAccounts(accounts)
        }
    }

    private func persistQuota(identity: String, quota: Quota) async {
        _ = try? await repository.transaction { document in
            var accounts = document.accounts
            guard var account = accounts[identity] as? [String: Any] else { return }
            account["quota"] = [
                "remainingSeconds": quota.remainingSeconds,
                "newDevice": quota.newDevice,
                "checkedAtMillis": quota.checkedAtMillis
            ]
            account["quotaError"] = false
            accounts[identity] = account
            try document.setAccounts(accounts)
        }
    }

    private func commitReportOutcome(
        identity: String,
        reportedSeconds: Int,
        quota: Quota?,
        record: UsageReportRecord
    ) async {
        let limit = maxRecordHistory
        _ = try? await repository.transaction { document in
            var accounts = document.accounts
            var account = accounts[identity] as? [String: Any] ?? [:]
            let rawLedger = account["ledger"] as? [String: Any] ?? [:]
            var ledger = AccountUsageLedger.fromJson(identity: identity, rawLedger)
            if reportedSeconds > 0 {
                ledger.pendingSeconds = max(0, ledger.pendingSeconds - reportedSeconds)
                ledger.totalReportedSeconds += reportedSeconds
                ledger.lastReportedAtMs = record.timestampMs
            }
            ledger.records.insert(record, at: 0)
            if ledger.records.count > limit {
                ledger.records = Array(ledger.records.prefix(limit))
            }
            var mergedLedger = rawLedger
            for (key, value) in ledger.toJson() {
                mergedLedger[key] = value
            }
            account["ledger"] = mergedLedger
            if let quota {
                account["quota"] = [
                    "remainingSeconds": quota.remainingSeconds,
                    "newDevice": quota.newDevice,
                    "checkedAtMillis": quota.checkedAtMillis
                ]
                account["quotaError"] = false
            }
            accounts[identity] = account
            try document.setAccounts(accounts)
        }
    }
}
