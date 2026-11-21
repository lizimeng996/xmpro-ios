
import Foundation

// 安装设备标识。服务图只创建一个实例：多个实例各自缓存时，
// 并发首次调用可能生成不同值（后写入 Keychain 者胜出，各实例缓存仍可能分叉）。
actor InstallDevice {
    private static let account = "install.deviceId"

    private let store: any KeychainStore
    private var cached: String?
    private var persisted = false

    // 非抛错接口通过此属性公开固定、脱敏的存储错误。
    private(set) var lastError: XmlyError?

    init(store: any KeychainStore = SecItemKeychainStore()) {
        self.store = store
    }

    func deviceId() async -> String {
        if persisted, let cached { return cached }

        do {
            if let data = try store.load(
                account: Self.account, service: CredentialsVault.service
            ), let text = String(data: data, encoding: .utf8) {
                let normalized = text.lowercased()
                if Self.isValid(normalized) {
                    cached = normalized
                    persisted = true
                    lastError = nil
                    return normalized
                }
            }

            let value = cached ?? Self.generate()
            cached = value
            try store.save(
                account: Self.account,
                service: CredentialsVault.service,
                data: Data(value.utf8)
            )
            persisted = true
            lastError = nil
            return value
        } catch {
            // 签名要求非抛错：暂存进程内身份，下次调用继续尝试 Keychain。
            // 首次解锁前或 Keychain 故障期间不能承诺跨进程持久性。
            let value = cached ?? Self.generate()
            cached = value
            lastError = .failure(
                code: .invalidCredentials, message: "安全凭据存储不可用"
            )
            return value
        }
    }

    func deviceIdForLogin(credentials: Credentials?) async -> String {
        if let credentials { return credentials.deviceId }
        return await deviceId()
    }

    private static func isValid(_ value: String) -> Bool {
        ProtocolBytes.fullMatch(
            #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            value
        )
    }

    private static func generate() -> String {
        var uuid = UUID().uuid
        var bytes = withUnsafeBytes(of: &uuid) { Array($0) }
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80

        return [
            ProtocolBytes.hex(Array(bytes[0..<4])),
            ProtocolBytes.hex(Array(bytes[4..<6])),
            ProtocolBytes.hex(Array(bytes[6..<8])),
            ProtocolBytes.hex(Array(bytes[8..<10])),
            ProtocolBytes.hex(Array(bytes[10..<16]))
        ].joined(separator: "-")
    }
}
