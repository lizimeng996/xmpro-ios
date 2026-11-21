// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import XMPro

final class UsageLedgerTests: XCTestCase {
    private final class MutableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var currentMs: Int64

        init(_ startMs: Int64 = 1_700_000_000_000) {
            currentMs = startMs
        }

        func now() -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            return currentMs
        }

        func advance(seconds: Int64) {
            lock.lock()
            currentMs += seconds * 1_000
            lock.unlock()
        }
    }

    private func makeRepository() throws -> (StateRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmpro-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = try StateRepository.open(directory: dir)
        return (repo, dir)
    }

    func testCountsOnlyRealPlayingTimeAcrossPauseSeekAndSpeedChange() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = MutableClock()
        let ledger = UsageLedger(repository: repo, nowMs: { clock.now() })
        let identity = "acc-alpha"

        // 开始付费播放 12 秒
        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: true, requiresReward: true)
        clock.advance(seconds: 12)
        // 倍速改为 2.0x 不改变墙钟计时
        await ledger.onSpeedChanged(identity: identity, speed: 2.0)
        clock.advance(seconds: 8)
        // 拖动进度条：只结算前面 20 秒，不计入跳跃
        await ledger.onSeek(identity: identity)
        // 暂停 100 秒不累计
        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: false, requiresReward: true)
        clock.advance(seconds: 100)
        // 免费播放 15 秒：累计总听时，但不计入待扣减 pendingSeconds
        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: true, requiresReward: false)
        clock.advance(seconds: 15)
        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: false, requiresReward: false)

        let snap = await ledger.snapshot(identity: identity)
        XCTAssertEqual(snap.accumulatedSeconds, 35)
        XCTAssertEqual(snap.pendingSeconds, 20)
        XCTAssertEqual(snap.totalReportedSeconds, 0)
    }

    func testAccountIsolationKeepsLedgersSeparate() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = MutableClock()
        let ledger = UsageLedger(repository: repo, nowMs: { clock.now() })

        await ledger.onPlaybackStateChanged(identity: "acc-1", isPlaying: true, requiresReward: true)
        clock.advance(seconds: 30)
        await ledger.onPlaybackStateChanged(identity: "acc-1", isPlaying: false, requiresReward: true)

        await ledger.onPlaybackStateChanged(identity: "acc-2", isPlaying: true, requiresReward: true)
        clock.advance(seconds: 10)
        await ledger.onPlaybackStateChanged(identity: "acc-2", isPlaying: false, requiresReward: true)

        let snap1 = await ledger.snapshot(identity: "acc-1")
        let snap2 = await ledger.snapshot(identity: "acc-2")
        XCTAssertEqual(snap1.accumulatedSeconds, 30)
        XCTAssertEqual(snap1.pendingSeconds, 30)
        XCTAssertEqual(snap2.accumulatedSeconds, 10)
        XCTAssertEqual(snap2.pendingSeconds, 10)
    }

    func testReportPendingRecordsSuccessAndFailureAndPersistsAcrossReload() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        let context = try B1Fixture.context()
        let identity = context.identity
        let clock = MutableClock(B1Fixture.now)
        let serverClock = B1Fixture.clock()
        let ledger = UsageLedger(repository: repo, nowMs: { clock.now() })

        // 预写入账号节点以便验证 quota 字段更新
        try await repo.transaction { doc in
            var accounts = doc.accounts
            accounts[identity] = ["identity": identity, "rewardPaused": false]
            try doc.setAccounts(accounts)
        }

        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: true, requiresReward: true)
        clock.advance(seconds: 45)
        await ledger.onPlaybackStateChanged(identity: identity, isPlaying: false, requiresReward: true)

        // 先模拟失败上报：保留 pendingSeconds 并记录失败
        let failingHTTP = FakeHTTPTransport { _, _ in
            throw XmlyError.failure(code: .uncertain, message: "请求超时")
        }
        let failingClient = XmlyClientService(
            http: failingHTTP, accountContext: context, clock: serverClock
        )
        let failRecord = await ledger.reportPending(identity: identity, client: failingClient)
        XCTAssertEqual(failRecord?.status, .failed)
        XCTAssertEqual(failRecord?.seconds, 45)
        let afterFail = await ledger.snapshot(identity: identity)
        XCTAssertEqual(afterFail.pendingSeconds, 45)
        XCTAssertEqual(afterFail.records.count, 1)

        // 再模拟成功上报：清空 pendingSeconds、累计已上报并更新设备额度
        let encryptedRemaining = try XmlyCrypto.encrypt(
            "3555|\(serverClock.now())", key: XmlyCrypto.durationKey
        )
        let okHTTP = FakeHTTPTransport { _, _ in
            ["ret": 0, "data": ["availableListenDuration": encryptedRemaining]]
        }
        let okClient = XmlyClientService(
            http: okHTTP, accountContext: context, clock: serverClock
        )
        let okRecord = await ledger.reportPending(identity: identity, client: okClient)
        XCTAssertEqual(okRecord?.status, .succeeded)
        XCTAssertEqual(okRecord?.remainingAfter, 3_555)

        // 重开仓库验证持久化
        await repo.close()
        let reopened = try StateRepository.open(directory: dir)
        let ledger2 = UsageLedger(repository: reopened, nowMs: { clock.now() })
        let persisted = await ledger2.snapshot(identity: identity)
        XCTAssertEqual(persisted.pendingSeconds, 0)
        XCTAssertEqual(persisted.totalReportedSeconds, 45)
        XCTAssertEqual(persisted.records.count, 2)
        XCTAssertEqual(persisted.records.first?.status, .succeeded)
    }
}
