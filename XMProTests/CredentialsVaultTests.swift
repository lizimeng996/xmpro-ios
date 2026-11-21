
import Foundation
import XCTest
@testable import XMPro

final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Data]] = [:]
    private var rejectSaves = false
    private var rejectLoads = false
    private var remainingAllowedSaves: Int?

    /// 仅允许指定次数的保存，之后保存失败（nil 为不限）。
    /// 用于构造“首次保存成功、补偿保存失败”的导入回滚场景。
    var allowedSaves: Int? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return remainingAllowedSaves
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            remainingAllowedSaves = newValue
        }
    }

    var failSaves: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rejectSaves
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            rejectSaves = newValue
        }
    }

    var failLoads: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return rejectLoads
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            rejectLoads = newValue
        }
    }

    func save(account: String, service: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if rejectSaves {
            throw XmlyError.failure(
                code: .invalidCredentials, message: "合成存储故障"
            )
        }
        if let remaining = remainingAllowedSaves {
            guard remaining > 0 else {
                throw XmlyError.failure(
                    code: .invalidCredentials, message: "合成存储故障"
                )
            }
            remainingAllowedSaves = remaining - 1
        }
        values[service, default: [:]][account] = data
    }

    func load(account: String, service: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if rejectLoads {
            throw XmlyError.failure(
                code: .invalidCredentials, message: "合成读取故障"
            )
        }
        return values[service]?[account]
    }

    func delete(account: String, service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[service]?.removeValue(forKey: account)
    }

    func allAccounts(service: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values[service]?.keys ?? Dictionary<String, Data>().keys).sorted()
    }
}

final class CredentialsVaultTests: XCTestCase {
    func testSaveLoadRoundTrip() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let credentials = try fixture(1)

        try await vault.save(credentials)
        let actual = try await vault.load(identity: credentials.identity)

        XCTAssertTrue(actual?.token == credentials.token, "vault_roundtrip_token")
        XCTAssertTrue(actual?.deviceId == credentials.deviceId, "vault_roundtrip_device")
        XCTAssertTrue(actual?.identity == credentials.identity, "vault_roundtrip_identity")
    }

    func testMissingEntryReturnsNil() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let credentials = try fixture(1)

        let absent = try await vault.load(identity: credentials.identity)
        XCTAssertNil(absent, "vault_missing")

        // 单条目编码损坏（非 JSON、缺字段）一律返回 nil，不抛错。
        try memory.save(
            account: credentials.identity,
            service: CredentialsVault.service,
            data: Data("not-json".utf8)
        )
        let corrupt = try await vault.load(identity: credentials.identity)
        XCTAssertNil(corrupt, "vault_corrupt_json")
        try memory.save(
            account: credentials.identity,
            service: CredentialsVault.service,
            data: Data(#"{"token":"123456&fixture-token-1"}"#.utf8)
        )
        let missingField = try await vault.load(identity: credentials.identity)
        XCTAssertNil(missingField, "vault_missing_device_field")
    }

    func testRemoveClearsIdentity() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let credentials = try fixture(1)
        try await vault.save(credentials)
        try await vault.remove(identity: credentials.identity)

        let identities = try await vault.identities()
        let loaded = try await vault.load(identity: credentials.identity)
        let accounts = try memory.allAccounts(service: CredentialsVault.service)
        XCTAssertTrue(identities.isEmpty, "vault_remove_identities")
        XCTAssertNil(loaded, "vault_remove_load")
        XCTAssertTrue(accounts.isEmpty, "vault_remove_entries")
    }

    func testIdentitiesListsMultipleAccountsOnly() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let first = try fixture(1)
        let second = try fixture(2)
        try await vault.save(first)
        try await vault.save(second)
        try memory.save(
            account: "install.deviceId",
            service: CredentialsVault.service,
            data: Data("fixture-install".utf8)
        )
        // 损坏条目与非账号条目均不列入有效身份。
        try memory.save(
            account: "corrupt-fixture",
            service: CredentialsVault.service,
            data: Data("not-json".utf8)
        )

        let identities = try await vault.identities()
        XCTAssertTrue(
            identities == [first.identity, second.identity].sorted(),
            "vault_multiple_identities"
        )
    }

    func testInvalidStoredCredentialsReturnNil() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let credentials = try fixture(1)
        try await vault.save(credentials)

        try memory.save(
            account: credentials.identity,
            service: CredentialsVault.service,
            data: Data("invalid-fixture".utf8)
        )
        let invalidToken = try await vault.load(identity: credentials.identity)
        XCTAssertNil(invalidToken, "vault_invalid_token")

        try memory.save(
            account: credentials.identity,
            service: CredentialsVault.service,
            data: Data([0xff, 0xfe])
        )
        let invalidEncoding = try await vault.load(identity: credentials.identity)
        XCTAssertNil(invalidEncoding, "vault_invalid_encoding")
    }

    func testMismatchedIdentityReturnsNil() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let first = try fixture(1)
        let second = try fixture(2)
        try await vault.save(first)
        // 用第二账号的凭据覆盖第一账号的单条目：身份不匹配，返回 nil。
        let secondData = try JSONSerialization.data(
            withJSONObject: [
                "device": second.deviceId,
                "token": second.token
            ],
            options: [.sortedKeys]
        )
        try memory.save(
            account: first.identity,
            service: CredentialsVault.service,
            data: secondData
        )
        let actual = try await vault.load(identity: first.identity)
        XCTAssertNil(actual, "vault_identity_mismatch")
    }

    func testFailedSaveKeepsOldCredentials() async throws {
        let memory = InMemoryKeychainStore()
        let vault = CredentialsVault(store: memory)
        let first = try fixture(1)
        let second = try fixture(2)
        try await vault.save(first)

        // 单条目写入是单操作：失败时旧值保持完整，无需补偿恢复。
        memory.failSaves = true
        do {
            try await vault.save(second)
            XCTFail("vault_failed_save")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "vault_failed_save_code")
        } catch {
            XCTFail("vault_failed_save_type")
        }
        memory.failSaves = false

        let actual = try await vault.load(identity: first.identity)
        XCTAssertTrue(actual?.token == first.token, "vault_failed_save_kept_token")
        XCTAssertTrue(actual?.deviceId == first.deviceId, "vault_failed_save_kept_device")
        let noSecond = try await vault.load(identity: second.identity)
        XCTAssertNil(noSecond, "vault_failed_save_no_second")

        // 同一 identity 的更新失败同样不破坏旧值（复审追问的用例）。
        // identity 由 uid|deviceId 决定：同 deviceId、换 token 仍是同一账号。
        memory.failSaves = true
        do {
            try await vault.save(
                Credentials(token: "123456&fixture-token-1-updated", deviceId: "fixture-device-1")
            )
            XCTFail("vault_failed_update")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_credentials", "vault_failed_update_code")
        } catch {
            XCTFail("vault_failed_update_type")
        }
        memory.failSaves = false
        let kept = try await vault.load(identity: first.identity)
        XCTAssertTrue(kept?.token == first.token, "vault_failed_update_kept")
    }

    func testInstallDevicePersistsAndIsNotAnAccount() async throws {
        let memory = InMemoryKeychainStore()
        let first = InstallDevice(store: memory)
        let firstValue = await first.deviceId()
        let second = InstallDevice(store: memory)
        let secondValue = await second.deviceId()

        XCTAssertTrue(firstValue == secondValue, "install_persisted")
        XCTAssertTrue(
            ProtocolBytes.fullMatch(
                #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                firstValue
            ),
            "install_uuid_v4"
        )
        let credentials = try fixture(1)
        let loginValue = await first.deviceIdForLogin(credentials: credentials)
        XCTAssertTrue(loginValue == credentials.deviceId, "install_login_override")

        let vault = CredentialsVault(store: memory)
        let identities = try await vault.identities()
        XCTAssertTrue(identities.isEmpty, "install_not_account")
    }

    #if os(iOS)
    // 待执行侧在具备 Keychain 的 iOS 模拟器或真机环境验证。
    func testSecItemKeychainSmoke() throws {
        let store = SecItemKeychainStore()
        let account = "test.fixture.\(UUID().uuidString)"
        let service = CredentialsVault.service
        let data = Data("synthetic-keychain-fixture".utf8)

        do {
            try store.save(account: account, service: service, data: data)
        } catch {
            throw XCTSkip("keychain_smoke_unavailable")
        }
        defer { try? store.delete(account: account, service: service) }

        let loaded = try store.load(account: account, service: service)
        XCTAssertTrue(loaded == data, "keychain_smoke_read")
        try store.delete(account: account, service: service)
        let removed = try store.load(account: account, service: service)
        XCTAssertNil(removed, "keychain_smoke_delete")
    }
    #endif

    private func fixture(_ number: Int) throws -> Credentials {
        try Credentials(
            token: "\(123455 + number)&fixture-token-\(number)",
            deviceId: "fixture-device-\(number)"
        )
    }
}
