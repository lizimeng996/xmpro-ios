import Foundation
import XCTest
@testable import XMPro

@MainActor
final class AppDependenciesTests: XCTestCase {
    // Keychain 的 load 接口未在交付上下文中给出；在相同的
    // await clientFactory() 边界注入 continuation，等价模拟首次凭据读取挂起。
    // 测试关闭初始化自动刷新，显式持有两个刷新任务；等待挂起确认、第二次
    // 完成、再释放并 await 第一次完成，全程不依赖 sleep 或调度概率。
    @MainActor
    private final class SuspendedClientFactory {
        private let second: XmlyClientService
        private var firstContinuation: CheckedContinuation<XmlyClientService, Error>?
        private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
        private(set) var calls = 0
        private var suspended = false

        init(second: XmlyClientService) {
            self.second = second
        }

        func make() async throws -> XmlyClientService {
            calls += 1
            guard calls == 1 else { return second }
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
                suspended = true
                let waiters = suspensionWaiters
                suspensionWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        func waitUntilSuspended() async {
            guard !suspended else { return }
            await withCheckedContinuation { suspensionWaiters.append($0) }
        }

        func finishFirst(_ result: Result<XmlyClientService, Error>) {
            let continuation = firstContinuation
            firstContinuation = nil
            continuation?.resume(with: result)
        }
    }

    private func assertStaleRefreshIsIgnored(fails: Bool) async throws {
        let h = try S4Harness(test: self)
        let transport = FakeHTTPTransport { call, _ in
            if call.path == "/revision/user" {
                return ["data": [:]]
            }
            return ["data": ["nickname": "合成账号资料"]]
        }
        let firstClient = XmlyClientService(
            http: transport,
            accountContext: try B1Fixture.context("101"),
            clock: B1Fixture.clock()
        )
        let secondClient = XmlyClientService(
            http: transport,
            accountContext: try B1Fixture.context("202"),
            clock: B1Fixture.clock()
        )
        let factory = SuspendedClientFactory(second: secondClient)
        let dependencies = AppDependencies(
            serverClock: B1Fixture.clock(),
            http: transport,
            stateRepository: h.repository,
            credentialsVault: h.vault,
            clientFactory: { try await factory.make() },
            automaticallyRefreshAccounts: false
        )
        let initialRevision = dependencies.accountRevision

        let firstRefresh = Task { await dependencies.refreshAccountServices() }
        await factory.waitUntilSuspended()
        XCTAssertEqual(dependencies.accountRevision, initialRevision)

        await dependencies.refreshAccountServices()
        let publishedService = dependencies.experienceService
        XCTAssertEqual(factory.calls, 2)
        XCTAssertEqual(dependencies.accountRevision, initialRevision + 1)

        if fails {
            factory.finishFirst(.failure(XmlyError.failure(
                code: .network, message: "合成迟到失败"
            )))
        } else {
            factory.finishFirst(.success(firstClient))
        }
        await firstRefresh.value

        XCTAssertEqual(dependencies.accountRevision, initialRevision + 1)
        XCTAssertTrue(dependencies.experienceService === publishedService)
        let profile = try await dependencies.experienceService.profile()
        b1Check(profile.uid == "202", "s4-refresh-latest-account")
    }

    func testLateRefreshSuccessCannotReplaceLatestAccountService() async throws {
        try await assertStaleRefreshIsIgnored(fails: false)
    }

    func testLateRefreshFailureCannotReplaceLatestAccountService() async throws {
        try await assertStaleRefreshIsIgnored(fails: true)
    }

    func testExportBackupWithoutDeliveryFailsBeforeSerialization() async throws {
        let h = try S4Harness(test: self)
        var generated = 0
        let backup = BackupService(now: {
            generated += 1
            return Date(timeIntervalSince1970: 1_800_000_000)
        })
        let dependencies = AppDependencies(
            http: FakeHTTPTransport { _, _ in [:] },
            stateRepository: h.repository,
            credentialsVault: h.vault,
            backupService: backup,
            automaticallyRefreshAccounts: false
        )
        XCTAssertNil(dependencies.onExportBackup)
        let before = try await h.repository.state().encoded()
        var returned: Data?
        do {
            returned = try await dependencies.exportBackup(includeCredentials: true)
            XCTFail("s4-export-unwired")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "uncertain")
            XCTAssertEqual(
                error.message, "备份导出未接线：宿主未提供文件保存入口"
            )
        }
        XCTAssertNil(returned)
        XCTAssertEqual(generated, 0)
        let after = try await h.repository.state().encoded()
        b1Check(before == after, "s4-export-unwired-state")
    }

    func testExportBackupDeliversExactlyGeneratedData() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()

        // 固定 exportedAt，避免两次导出跨毫秒导致字节比较偶发失败。
        let backup = BackupService(now: {
            Date(timeIntervalSince1970: 1_800_000_000)
        })
        let dependencies = AppDependencies(
            http: FakeHTTPTransport { _, _ in [:] },
            stateRepository: h.repository,
            credentialsVault: h.vault,
            backupService: backup,
            automaticallyRefreshAccounts: false
        )
        var deliveries: [Data] = []
        dependencies.onExportBackup = { deliveries.append($0) }

        for includeCredentials in [false, true] {
            deliveries.removeAll()
            let document = await h.repository.state()
            let expected = try await dependencies.backupService.export(
                state: document.json,
                includeCredentials: includeCredentials,
                vault: h.vault
            )
            let returned = try await dependencies.exportBackup(
                includeCredentials: includeCredentials
            )
            b1Check(deliveries.count == 1, "s4-export-delivery-count")
            b1Check(deliveries.first == returned, "s4-export-delivery-bytes")
            b1Check(returned == expected, "s4-export-direct-bytes")
        }
    }
}
