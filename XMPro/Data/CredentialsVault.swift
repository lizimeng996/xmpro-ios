
import Foundation
import Security

protocol KeychainStore: Sendable {
    func save(account: String, service: String, data: Data) throws
    func load(account: String, service: String) throws -> Data?
    func delete(account: String, service: String) throws
    func allAccounts(service: String) throws -> [String]
}

struct SecItemKeychainStore: KeychainStore {
    func save(account: String, service: String, data: Data) throws {
        var attributes = query(account: account, service: service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            guard SecItemUpdate(
                query(account: account, service: service) as CFDictionary,
                changes as CFDictionary
            ) == errSecSuccess else {
                throw Self.failure
            }
        } else if status != errSecSuccess {
            throw Self.failure
        }
    }

    func load(account: String, service: String) throws -> Data? {
        var request = query(account: account, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Self.failure
        }
        return data
    }

    func delete(account: String, service: String) throws {
        let status = SecItemDelete(
            query(account: account, service: service) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure
        }
    }

    func allAccounts(service: String) throws -> [String] {
        var request = query(account: nil, service: service)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            throw Self.failure
        }
        return Array(Set(items.compactMap {
            $0[kSecAttrAccount as String] as? String
        })).sorted()
    }

    private func query(account: String?, service: String) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false
        ]
        if let account {
            result[kSecAttrAccount as String] = account
        }
        return result
    }

    private static var failure: XmlyError {
        .failure(code: .invalidCredentials, message: "安全凭据存储不可用")
    }
}

actor CredentialsVault {
    static let service = "studio.teikeng.xmpro.credentials"

    // 一个 identity 的 token/device 编码为单条 Keychain 项：SecItem 单操作
    // 是原子的，避免双条记录的部分提交窗口。Keychain 是平台本地存储，
    // 与 Kotlin 的双键布局不构成跨端契约；本应用尚未发布，无旧数据要迁移。
    private static let installDeviceAccount = "install.deviceId"

    private let store: any KeychainStore

    init(store: any KeychainStore = SecItemKeychainStore()) {
        self.store = store
    }

    func save(_ credentials: Credentials) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: [
                    "device": credentials.deviceId,
                    "token": credentials.token
                ],
                options: [.sortedKeys]
            )
        } catch {
            throw Self.failure
        }
        do {
            try store.save(
                account: credentials.identity,
                service: Self.service,
                data: data
            )
        } catch {
            throw Self.failure
        }
    }

    func load(identity: String) throws -> Credentials? {
        let data: Data?
        do {
            data = try store.load(account: identity, service: Self.service)
        } catch {
            throw Self.failure
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let token = object["token"] as? String,
              let device = object["device"] as? String,
              let credentials = try? Credentials(token: token, deviceId: device),
              credentials.identity == identity else {
            return nil
        }
        return credentials
    }

    func remove(identity: String) throws {
        do {
            try store.delete(account: identity, service: Self.service)
        } catch {
            throw Self.failure
        }
    }

    // 有效凭据身份：逐条 load 校验（损坏 JSON、缺字段、identity 不匹配
    // 的条目均不列入）；安装标识不属于账号，同样排除。存储本身读取失败时
    // 抛错，不静默跳过。调用方可以把返回值当作有效账号列表。
    func identities() throws -> [String] {
        do {
            var result: [String] = []
            for account in try store.allAccounts(service: Self.service)
            where account != Self.installDeviceAccount {
                if try load(identity: account) != nil {
                    result.append(account)
                }
            }
            return result.sorted()
        } catch {
            throw Self.failure
        }
    }

    private static var failure: XmlyError {
        .failure(code: .invalidCredentials, message: "安全凭据存储不可用")
    }
}
