
import Foundation
import XCTest
@testable import XMPro

final class AccountStoreTests: XCTestCase {
    private struct Harness {
        let repository: StateRepository
        let vault: CredentialsVault
        let keychain: InMemoryKeychainStore
        let store: AccountStore
    }

    func testImportedAccountsKeepIndependentContexts() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        let initial = try await h.store.activeContext()
        assertContext(initial, matches: first, caseID: "isolation_first")

        try await h.store.switchAccount(identity: second.identity)
        let switched = try await h.store.activeContext()
        assertContext(switched, matches: second, caseID: "isolation_second")

        let firstStored = try await h.vault.load(identity: first.identity)
        let secondStored = try await h.vault.load(identity: second.identity)
        XCTAssertTrue(firstStored?.token == first.token, "isolation_first_vault")
        XCTAssertTrue(secondStored?.token == second.token, "isolation_second_vault")

        let document = await h.repository.state()
        XCTAssertEqual(document.accounts.count, 2, "isolation_state_count")
        XCTAssertNoThrow(try document.validate(), "isolation_state_validate")
    }

    func testSwitchChangesActiveButNotPrimary() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        try await h.store.switchAccount(identity: second.identity)
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        let all = await h.store.allAccounts()

        XCTAssertTrue(active?.identity == second.identity, "switch_active")
        XCTAssertTrue(primary?.identity == first.identity, "switch_primary")
        XCTAssertTrue(all.first?.identity == first.identity, "switch_primary_first")
    }

    func testRemovePrimaryPromotesRemainingAccount() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        await h.store.removeAccount(identity: first.identity)
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        let removed = try await h.vault.load(identity: first.identity)
        let remaining = try await h.vault.load(identity: second.identity)
        let document = await h.repository.state()

        XCTAssertTrue(primary?.identity == second.identity, "remove_primary_promoted")
        XCTAssertTrue(active?.identity == second.identity, "remove_primary_active")
        XCTAssertNil(removed, "remove_primary_vault")
        XCTAssertTrue(remaining?.token == second.token, "remove_primary_other_vault")
        XCTAssertNil(document.accounts[first.identity], "remove_primary_state")
    }

    func testRemoveAllClearsActiveAndPrimary() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        await h.store.removeAccount(identity: first.identity)
        await h.store.removeAccount(identity: second.identity)
        let document = await h.repository.state()
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        let identities = try await h.vault.identities()

        XCTAssertTrue(document.value(forKey: "activeAccountId") is NSNull, "remove_all_active_null")
        XCTAssertTrue(document.value(forKey: "primaryAccountId") is NSNull, "remove_all_primary_null")
        XCTAssertTrue(document.accounts.isEmpty, "remove_all_accounts")
        XCTAssertTrue(identities.isEmpty, "remove_all_vault")
        XCTAssertNil(active, "remove_all_active")
        XCTAssertNil(primary, "remove_all_primary")

        do {
            _ = try await h.store.activeContext()
            XCTFail("remove_all_context")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "login_required", "remove_all_context_code")
        } catch {
            XCTFail("remove_all_context_type")
        }
    }

    func testInvalidImportDoesNotWriteState() async throws {
        let h = try makeHarness()
        let before = try await h.repository.state().encoded()

        // 凭据在 actor 隔离边界外解析：非法输入在进 store 之前就抛错。
        do {
            _ = try Credentials.parse(["token": "invalid-fixture"])
            XCTFail("invalid_import")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "invalid_import_code")
        } catch {
            XCTFail("invalid_import_type")
        }

        let after = try await h.repository.state().encoded()
        let identities = try await h.vault.identities()
        XCTAssertTrue(before == after, "invalid_import_state")
        XCTAssertTrue(identities.isEmpty, "invalid_import_vault")
    }

    func testVaultFailureDoesNotWriteState() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        let before = try await h.repository.state().encoded()
        h.keychain.failSaves = true

        do {
            _ = try await importFixture(credentials, into: h.store)
            XCTFail("vault_failure_import")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "vault_failure_code")
        } catch {
            XCTFail("vault_failure_type")
        }

        let after = try await h.repository.state().encoded()
        XCTAssertTrue(before == after, "vault_failure_state")
    }

    func testUpdateQuotaIsVisibleAndStoredAsMilliseconds() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await importFixture(credentials, into: h.store)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let quota = try Quota(
            remainingSeconds: 3600, newDevice: true, checkedAt: date
        )

        await h.store.updateQuota(identity: credentials.identity, quota: quota)
        let summary = await h.store.activeAccount()
        let document = await h.repository.state()
        let account = document.accounts[credentials.identity] as? [String: Any]
        let stored = account?["quota"] as? [String: Any]

        XCTAssertEqual(summary?.quota?.remainingSeconds, 3600, "quota_remaining")
        XCTAssertTrue(summary?.quota?.newDevice == true, "quota_device")
        XCTAssertTrue(summary?.quota?.checkedAt == date, "quota_date")
        XCTAssertEqual(
            (stored?["checkedAt"] as? NSNumber)?.int64Value,
            1_700_000_000_000,
            "quota_milliseconds"
        )
    }

    func testNegativeStoredQuotaIsAbsent() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await importFixture(credentials, into: h.store)
        try await h.repository.transaction { document in
            var accounts = document.accounts
            var account = accounts[credentials.identity] as? [String: Any] ?? [:]
            account["quota"] = [
                "remainingSeconds": -1,
                "newDevice": false,
                "checkedAt": 1_700_000_000_000
            ]
            accounts[credentials.identity] = account
            try document.setAccounts(accounts)
        }
        let summary = await h.store.activeAccount()
        XCTAssertNil(summary?.quota, "quota_negative")
    }

    func testSetPausedUpdatesOnlyTargetAccount() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        await h.store.setPaused(identity: first.identity, paused: true)
        let paused = await h.store.allAccounts()
        XCTAssertTrue(
            paused.first(where: { $0.identity == first.identity })?.paused == true,
            "paused_target"
        )
        XCTAssertTrue(
            paused.first(where: { $0.identity == second.identity })?.paused == false,
            "paused_other"
        )

        await h.store.setPaused(identity: first.identity, paused: false)
        let resumed = await h.store.primaryAccount()
        XCTAssertTrue(resumed?.paused == false, "paused_reset")
    }

    func testMissingVaultEntryDoesNotFallBackAtStartup() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)
        try await h.store.switchAccount(identity: second.identity)
        try await h.vault.remove(identity: second.identity)

        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        XCTAssertNil(active, "startup_missing_active")
        XCTAssertTrue(primary?.identity == first.identity, "startup_primary_retained")

        do {
            _ = try await h.store.activeContext()
            XCTFail("startup_context")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "login_required", "startup_context_code")
        } catch {
            XCTFail("startup_context_type")
        }
    }

    func testSwitchToMissingCredentialsDoesNotChangeActive() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await importFixture(credentials, into: h.store)

        do {
            try await h.store.switchAccount(identity: "missing-fixture")
            XCTFail("switch_missing")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "missing_account", "switch_missing_code")
        } catch {
            XCTFail("switch_missing_type")
        }
        let active = await h.store.activeAccount()
        XCTAssertTrue(active?.identity == credentials.identity, "switch_missing_unchanged")
    }

    func testReimportPreservesUnknownAccountFields() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await importFixture(credentials, into: h.store)
        try await h.repository.transaction { document in
            var accounts = document.accounts
            var account = accounts[credentials.identity] as? [String: Any] ?? [:]
            account["futureAccountField"] = ["values": [1, 2, 3]]
            accounts[credentials.identity] = account
            try document.setAccounts(accounts)
        }

        _ = try await importFixture(credentials, into: h.store)
        let document = await h.repository.state()
        let account = document.accounts[credentials.identity] as? [String: Any]
        let future = account?["futureAccountField"] as? [String: Any]
        XCTAssertTrue(future?["values"] as? [Int] == [1, 2, 3], "reimport_unknown")
    }

    func testRemoveActiveNonPrimaryLeavesActiveEmpty() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)
        try await h.store.switchAccount(identity: second.identity)
        await h.store.removeAccount(identity: second.identity)

        // 与 Kotlin removeAccount + signOut 一致：活动账号被删后不回退到
        // primary，保持空位；主账号仍保留。
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        let document = await h.repository.state()
        XCTAssertNil(active, "remove_active_nonprimary_active")
        XCTAssertTrue(primary?.identity == first.identity, "remove_active_nonprimary_primary")
        XCTAssertTrue(
            document.value(forKey: "activeAccountId") is NSNull,
            "remove_active_nonprimary_state"
        )
    }

    func testImportActivatesWhenNoActiveAccount() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        let third = try fixture(3)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)
        try await h.store.switchAccount(identity: second.identity)
        await h.store.removeAccount(identity: second.identity)
        // 断言参数是同步 autoclosure：先 await 取值，再断言。
        let noActive = await h.store.activeAccount()
        XCTAssertNil(noActive, "import_activate_before")

        _ = try await importFixture(third, into: h.store)
        // Kotlin signIn 规则：无活动账号时导入即激活；主账号不抢占。
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        XCTAssertTrue(active?.identity == third.identity, "import_activate_active")
        XCTAssertTrue(primary?.identity == first.identity, "import_activate_primary")
    }

    func testSetPrimaryAccountAndRename() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)

        try await h.store.setPrimaryAccount(identity: second.identity)
        let primary = await h.store.primaryAccount()
        let active = await h.store.activeAccount()
        XCTAssertTrue(primary?.identity == second.identity, "set_primary_primary")
        XCTAssertTrue(active?.identity == second.identity, "set_primary_active")

        await h.store.renameAccount(identity: second.identity, nickname: " 本地名 ")
        let renamed = await h.store.primaryAccount()
        XCTAssertTrue(renamed?.nickname == "本地名", "rename_trimmed")
    }

    func testRemovePrimaryWhenActiveIsNilFallsBackToNext() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let second = try fixture(2)
        let third = try fixture(3)
        _ = try await importFixture(first, into: h.store)
        _ = try await importFixture(second, into: h.store)
        _ = try await importFixture(third, into: h.store)
        try await h.store.switchAccount(identity: third.identity)
        // 删活动非主账号：活动保持空位（Kotlin signOut 行为）。
        await h.store.removeAccount(identity: third.identity)
        let nilBefore = await h.store.activeAccount()
        let primaryBefore = await h.store.primaryAccount()
        XCTAssertNil(nilBefore, "remove_primary_nil_before")
        XCTAssertTrue(
            primaryBefore?.identity == first.identity,
            "remove_primary_nil_primary"
        )

        // 再删主账号：活动账号原本为空，也要跟进为剩余首个账号。
        await h.store.removeAccount(identity: first.identity)
        let active = await h.store.activeAccount()
        let primary = await h.store.primaryAccount()
        XCTAssertTrue(primary?.identity == second.identity, "remove_primary_nil_next_primary")
        XCTAssertTrue(active?.identity == second.identity, "remove_primary_nil_next_active")
    }

    func testReimportPreservesProfileAndQuota() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await h.store.importCredentials(
            credentials,
            nickname: "测试账号",
            avatarUrl: "https://example.com/avatar.jpg",
            mobile: "13812345678"
        )
        let quota = try Quota(
            remainingSeconds: 3600, newDevice: false,
            checkedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await h.store.updateQuota(identity: credentials.identity, quota: quota)

        // 默认参数重导入：已有昵称／头像／手机号／额度全部保留，不被清空。
        _ = try await h.store.importCredentials(credentials)
        let summary = await h.store.activeAccount()
        XCTAssertTrue(summary?.nickname == "测试账号", "reimport_nickname")
        XCTAssertTrue(
            summary?.avatarUrl == "https://example.com/avatar.jpg", "reimport_avatar"
        )
        XCTAssertTrue(summary?.mobile == "138****5678", "reimport_mobile")
        XCTAssertEqual(summary?.quota?.remainingSeconds, 3600, "reimport_quota")
    }

    func testOrphanVaultCredentialExcludedFromAllAccounts() async throws {
        let h = try makeHarness()
        let first = try fixture(1)
        let orphan = try fixture(2)
        _ = try await importFixture(first, into: h.store)
        // 只写 Keychain、不写 state 的孤立凭据不列入账号列表。
        try await h.vault.save(orphan)

        let all = await h.store.allAccounts()
        XCTAssertEqual(all.count, 1, "orphan_all_count")
        XCTAssertTrue(all.first?.identity == first.identity, "orphan_all_identity")
        let vaultIdentities = try await h.vault.identities()
        XCTAssertTrue(
            vaultIdentities.contains(orphan.identity),
            "orphan_vault_still_lists"
        )
    }

    func testDeviceIdForLoginThrowsOnVaultFailure() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await importFixture(credentials, into: h.store)

        // 活动账号凭据读取失败时抛错，不静默降级为安装标识。
        h.keychain.failLoads = true
        do {
            _ = try await h.store.deviceIdForLogin()
            XCTFail("device_login_failure")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "device_login_failure_code")
        } catch {
            XCTFail("device_login_failure_type")
        }
        let failureCode = await h.store.lastFailureCode
        XCTAssertNotNil(failureCode, "device_login_failure_recorded")

        h.keychain.failLoads = false
        let deviceId = try await h.store.deviceIdForLogin()
        XCTAssertTrue(deviceId == credentials.deviceId, "device_login_account_device")

        // 无活动账号时取安装标识，不抛错。
        let fresh = try makeHarness()
        let installId = try await fresh.store.deviceIdForLogin()
        XCTAssertTrue(
            ProtocolBytes.fullMatch(
                #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                installId
            ),
            "device_login_install"
        )
    }

    func testRecoveryCodeClearedByLaterOperations() async throws {
        // 确定顺序的连续操作回归：先制造一次恢复失败，确认镜像为
        // recovery_failed；再依次执行无旧凭据的删除、vault 阶段失败的
        // 导入、成功导入，每一步后镜像都必须为 nil（旧码不残留）。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await store.importCredentials(first)

        try FileManager.default.removeItem(at: directory)
        keychain.failSaves = true
        let failed = await store.removeAccount(identity: first.identity)
        XCTAssertEqual(failed, .failed, "sequence_recovery_failed")
        let markedCode = await store.lastRecoveryFailureCode
        XCTAssertEqual(markedCode, "recovery_failed", "sequence_marked")

        // 无旧凭据的删除：state 提交失败但无需补偿，镜像清零。
        let noPrevious = await store.removeAccount(identity: second.identity)
        XCTAssertEqual(noPrevious, .none, "sequence_no_previous")
        let clearedAfterRemove = await store.lastRecoveryFailureCode
        XCTAssertNil(clearedAfterRemove, "sequence_cleared_after_remove")

        // vault 阶段失败的导入：不经过补偿，镜像保持 nil。
        do {
            _ = try await store.importCredentials(second)
            XCTFail("sequence_vault_failure")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "sequence_vault_code")
        } catch {
            XCTFail("sequence_vault_type")
        }
        let clearedAfterVaultFailure = await store.lastRecoveryFailureCode
        XCTAssertNil(clearedAfterVaultFailure, "sequence_cleared_after_vault")

        // 成功导入：镜像保持 nil。
        keychain.failSaves = false
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let summary = try await store.importCredentials(second)
        XCTAssertEqual(summary.identity, second.identity, "sequence_success_import")
        let clearedAfterSuccess = await store.lastRecoveryFailureCode
        XCTAssertNil(clearedAfterSuccess, "sequence_cleared_after_success")
    }

    func testRemoveAccountRecoveryFailureIsObservable() async throws {
        // 删 Keychain 成功 → state 提交失败（目录已删）→ 恢复凭据也失败：
        // lastRecoveryFailureCode 必须记为 recovery_failed，调用方可据此
        // 区分“已恢复”与“凭据已丢失”。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = try fixture(1)
        _ = try await store.importCredentials(credentials)

        try FileManager.default.removeItem(at: directory)
        keychain.failSaves = true
        let recovery = await store.removeAccount(identity: credentials.identity)
        keychain.failSaves = false

        let failureCode = await store.lastFailureCode
        let recoveryCode = await store.lastRecoveryFailureCode
        XCTAssertEqual(recovery, .failed, "recovery_return_failed")
        XCTAssertEqual(failureCode, "write_failed", "recovery_failure_code")
        XCTAssertEqual(recoveryCode, "recovery_failed", "recovery_failure_marked")
        let loaded = try await vault.load(identity: credentials.identity)
        XCTAssertNil(loaded, "recovery_failure_lost")
    }

    func testConcurrentRemovesReportOwnRecovery() async throws {
        // 并发删除两个账号：一个有凭据（补偿失败 → .failed），一个无凭据
        // （无需补偿 → .none）。返回值各自归属，不依赖事后读取会被
        // 后完成的操作覆盖的诊断属性。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let first = try fixture(1)
        let second = try fixture(2)
        _ = try await store.importCredentials(first)

        try FileManager.default.removeItem(at: directory)
        keychain.failSaves = true
        async let firstRecovery = store.removeAccount(identity: first.identity)
        async let secondRecovery = store.removeAccount(identity: second.identity)
        let (firstResult, secondResult) = await (firstRecovery, secondRecovery)
        keychain.failSaves = false

        XCTAssertEqual(firstResult, .failed, "concurrent_recovery_first")
        XCTAssertEqual(secondResult, .none, "concurrent_recovery_second")
    }

    func testRemoveWithoutPreviousCredentialsReportsNoRecovery() async throws {
        // 删除时 state 提交失败但该账号本无凭据：无需补偿，recovery 为 .none，
        // 诊断码不残留旧值。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = try fixture(1)
        try FileManager.default.removeItem(at: directory)

        let recovery = await store.removeAccount(identity: credentials.identity)

        XCTAssertEqual(recovery, .none, "remove_no_previous_recovery")
        let recoveryCode = await store.lastRecoveryFailureCode
        XCTAssertNil(recoveryCode, "remove_no_previous_code")
    }

    func testImportRollbackRestoresCredentialsOnStateFailure() async throws {
        // 导入时 vault 保存成功、state 提交失败（目录已删）：回滚删除新凭据，
        // 恢复成功时 lastRecoveryFailureCode 保持 nil。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = try fixture(1)
        try FileManager.default.removeItem(at: directory)

        do {
            _ = try await store.importCredentials(credentials)
            XCTFail("import_rollback_state")
        } catch let error as AccountStore.AccountImportError {
            XCTAssertEqual(error.failureCode, "write_failed", "import_rollback_code")
            XCTAssertEqual(error.recovery, .restored, "import_rollback_recovery")
        } catch {
            XCTFail("import_rollback_type")
        }

        let recoveryCode = await store.lastRecoveryFailureCode
        XCTAssertNil(recoveryCode, "import_rollback_recovered")
        let loaded = try await vault.load(identity: credentials.identity)
        XCTAssertNil(loaded, "import_rollback_removed")
    }

    func testImportRollbackFailureReportsRecoveryFailed() async throws {
        // 导入时 state 提交失败（目录已删）且回滚保存旧凭据也失败：
        // 抛 AccountImportError，recovery 为 .failed，失败码保留原始码。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let credentials = try fixture(1)
        _ = try await store.importCredentials(credentials)

        try FileManager.default.removeItem(at: directory)
        // 仅允许一次保存：新凭据写入成功，随后回滚保存旧凭据失败。
        keychain.allowedSaves = 1
        do {
            _ = try await store.importCredentials(credentials)
            XCTFail("import_rollback_failed_state")
        } catch let error as AccountStore.AccountImportError {
            XCTAssertEqual(error.failureCode, "write_failed", "import_rollback_failed_code")
            XCTAssertEqual(error.failureMessage, "状态文件写入失败", "import_rollback_failed_message")
            XCTAssertEqual(error.recovery, .failed, "import_rollback_failed_recovery")
        } catch {
            XCTFail("import_rollback_failed_type")
        }
        keychain.allowedSaves = nil

        let recoveryCode = await store.lastRecoveryFailureCode
        XCTAssertEqual(recoveryCode, "recovery_failed", "import_rollback_failed_marked")
    }

    func testImportStoresKotlinKeysAndMaskedMobile() async throws {
        let h = try makeHarness()
        let credentials = try fixture(1)
        _ = try await h.store.importCredentials(
            credentials,
            nickname: "测试账号",
            avatarUrl: "https://example.com/avatar.jpg",
            mobile: "13812345678"
        )

        let document = await h.repository.state()
        let account = document.accounts[credentials.identity] as? [String: Any]
        XCTAssertEqual(account?["deviceHint"] as? String, "…ce-1", "import_device_hint")
        XCTAssertEqual(account?["nickname"] as? String, "测试账号", "import_nickname")
        XCTAssertEqual(
            account?["avatar"] as? String,
            "https://example.com/avatar.jpg",
            "import_avatar_key"
        )
        XCTAssertEqual(account?["mobile"] as? String, "138****5678", "import_mobile_masked")
        XCTAssertEqual(account?["rewardPaused"] as? Bool, false, "import_reward_paused")
        XCTAssertEqual(account?["archived"] as? Bool, false, "import_archived")
        XCTAssertTrue(account?["ledger"] is [String: Any], "import_ledger")
        XCTAssertEqual(account?["quotaError"] as? Bool, true, "import_quota_error")
        XCTAssertNil(account?["quota"], "import_quota_absent")
        XCTAssertNil(account?["paused"], "import_no_legacy_paused_key")
        XCTAssertNil(account?["avatarUrl"], "import_no_legacy_avatar_key")

        let summary = await h.store.activeAccount()
        XCTAssertTrue(summary?.deviceHint == "…ce-1", "import_summary_hint")
        XCTAssertTrue(summary?.mobile == "138****5678", "import_summary_mobile")
        XCTAssertTrue(summary?.quotaRejected == true, "import_summary_quota_rejected")
    }

    private func makeHarness() throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "account-tests-\(UUID().uuidString)", isDirectory: true
            )
        let repository = try StateRepository.open(directory: directory)
        let keychain = InMemoryKeychainStore()
        let vault = CredentialsVault(store: keychain)
        let install = InstallDevice(store: keychain)
        let store = AccountStore(
            repository: repository, vault: vault, installDevice: install
        )
        addTeardownBlock {
            await repository.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return Harness(
            repository: repository, vault: vault, keychain: keychain, store: store
        )
    }

    private func fixture(_ number: Int) throws -> Credentials {
        try Credentials(
            token: "\(123455 + number)&fixture-token-\(number)",
            deviceId: "fixture-device-\(number)"
        )
    }

    private func importFixture(
        _ credentials: Credentials,
        into store: AccountStore
    ) async throws -> AccountSummary {
        try await store.importCredentials(credentials)
    }

    private func assertContext(
        _ context: AccountContext,
        matches credentials: Credentials,
        caseID: String
    ) {
        // 仅断言布尔结果，失败输出不展开任何凭据或完整摘要。
        XCTAssertTrue(context.identity == credentials.identity, caseID)
        XCTAssertTrue(context.uid == credentials.uid, caseID)
        XCTAssertTrue(context.deviceId == credentials.deviceId, caseID)
        XCTAssertTrue(context.tokenAfterUID == credentials.tokenAfterUID, caseID)
        XCTAssertTrue(
            context.liteContext == ProtocolConfig.liteContext(for: credentials),
            caseID
        )
    }
}
