
import Foundation

struct AccountSummary: Sendable, CustomStringConvertible,
                      CustomDebugStringConvertible, CustomReflectable {
    let identity: String
    let uid: String
    let deviceHint: String
    let quota: Quota?
    let paused: Bool
    let primary: Bool
    let active: Bool
    var quotaRejected: Bool = false
    var nickname: String = ""
    var avatarUrl: String? = nil
    var mobile: String = ""
    var followers: Int? = nil
    var following: Int? = nil
    var subscriptionCount: Int? = nil

    // 含完整 identity 摘要与手机号；诊断输出一律脱敏。
    var description: String { "AccountSummary(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": "redacted"])
    }
}

struct AccountContext: Sendable, CustomStringConvertible,
                       CustomDebugStringConvertible, CustomReflectable {
    let identity: String
    let uid: String
    let deviceId: String
    let tokenAfterUID: String
    let liteContext: [String: String]

    init(credentials: Credentials) {
        identity = credentials.identity
        uid = credentials.uid
        deviceId = credentials.deviceId
        tokenAfterUID = credentials.tokenAfterUID
        liteContext = ProtocolConfig.liteContext(for: credentials)
    }

    var description: String { "AccountContext(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": "redacted"])
    }
}

actor AccountStore {
    private let repository: StateRepository
    private let vault: CredentialsVault
    private let installDevice: InstallDevice

    // actor 在 await 处可重入；此门闩把跨 actor 的完整账号操作串行化。
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // 非抛错写接口保留失败码，调用方可据此展示失败状态。
    private(set) var lastFailureCode: String?

    // 跨存储（Keychain + state.json）补偿恢复的失败码：仅为诊断镜像，
    // 反映最近一次导入／删除操作的补偿结果。调用方不要跨 await 依赖它——
    // 并发操作会覆盖该属性；本次操作的恢复结果以返回值
    // `AccountRecovery`（删除）或抛出的 `AccountImportError.recovery`
    // （导入）为准。Keychain 与 state.json 不具备原子性，补偿也不能覆盖
    // 进程中断窗口。码值固定，不含任何凭据内容。
    private(set) var lastRecoveryFailureCode: String?

    // 本次跨存储操作的恢复结果（随操作返回／随错误抛出，不依赖事后读属性）。
    enum AccountRecovery: Equatable, CustomStringConvertible {
        /// 无需补偿（未发生跨存储不一致）。
        case none
        /// 补偿成功，已恢复到操作前状态。
        case restored
        /// 补偿失败：导入时清理失败可能留下孤立凭据（state 未引用）；
        /// 删除时 state 仍可能引用已丢失的凭据；两种情况都应提示用户
        /// 重新导入该账号，而不是当作普通失败重试。
        case failed

        var description: String {
            switch self {
            case .none: return "none"
            case .restored: return "restored"
            case .failed: return "recovery_failed"
            }
        }
    }

    /// 导入凭据时 state 提交失败的错误：携带原始失败码与本次补偿结果。
    /// 凭据读写阶段（vault.load／save）失败时不经过补偿，直接抛原始
    /// XmlyError，此时无需补偿，recovery 概念不适用。
    struct AccountImportError: Error, CustomStringConvertible {
        /// 原始失败码（XmlyError／StateError 的 code；其他错误为 "unknown"）。
        let failureCode: String
        /// 原始失败文案（不含凭据内容）。
        let failureMessage: String
        /// 本次跨存储补偿的结果。
        let recovery: AccountRecovery

        init(underlying: Error, recovery: AccountRecovery) {
            if let error = underlying as? XmlyError {
                self.failureCode = error.code
                self.failureMessage = error.message
            } else if let error = underlying as? StateError {
                self.failureCode = error.code
                self.failureMessage = error.message
            } else {
                self.failureCode = "unknown"
                self.failureMessage = underlying.localizedDescription
            }
            self.recovery = recovery
        }

        var description: String {
            "AccountImportError(failureCode: \(failureCode), recovery: \(recovery))"
        }
    }

    init(
        repository: StateRepository,
        vault: CredentialsVault,
        installDevice: InstallDevice
    ) {
        self.repository = repository
        self.vault = vault
        self.installDevice = installDevice
    }

    // 入口只接受已解析的 Sendable Credentials：调用方在 actor 隔离边界外
    // 完成 Credentials.parse，避免非 Sendable 的 Any 输入跨越隔离边界。
    func importCredentials(
        _ credentials: Credentials,
        nickname: String = "",
        avatarUrl: String? = nil,
        mobile: String = "",
        makePrimary: Bool = false
    ) async throws -> AccountSummary {
        await acquire()
        defer { release() }
        lastRecoveryFailureCode = nil

        let oldCredentials = try await vault.load(identity: credentials.identity)

        try await vault.save(credentials)
        do {
            try await repository.transaction { document in
                var accounts = document.accounts
                var account = accounts[credentials.identity] as? [String: Any] ?? [:]
                account["uid"] = credentials.uid
                account["deviceHint"] = Self.deviceHint(for: credentials.deviceId)
                // 与 Kotlin signIn 一致：资料只覆盖实际提供的非空值；
                // 默认参数不清空已有昵称／头像／手机号（Kotlin signIn(parsed)
                // 根本不碰这些字段，signIn(LoginResult) 也只在非空时更新）。
                if !nickname.isEmpty {
                    account["nickname"] = nickname
                }
                if !mobile.isEmpty {
                    account["mobile"] = Self.maskMobile(mobile)
                }
                if let avatarUrl {
                    account["avatar"] = avatarUrl
                }
                // Kotlin 键名：rewardPaused（非 paused）、archived、ledger、
                // quotaError（非 quotaRejected）。
                account["rewardPaused"] = false
                account["archived"] = false
                if account["ledger"] == nil {
                    account["ledger"] = [String: Any]()
                }
                if account["quota"] == nil {
                    // 本轮无网络取额度：新账号记为未核验（quotaError=true）；
                    // 已有额度则保留为未重新验证的缓存，不删除（Kotlin 每次
                    // 登录都会重查，失败时删旧额度；iOS 侧重查在 Round B
                    // 登录流程中做，届时再按 Kotlin 规则写回／清除）。
                    account["quotaError"] = true
                }
                accounts[credentials.identity] = account
                try document.setAccounts(accounts)
                // 与 Kotlin signIn 的激活规则一致：makePrimary 或主账号未设
                // 时设 primary；makePrimary 或活动账号未设时设 active。
                // 已有活动账号时不抢占。
                if makePrimary || document.primaryAccountId == nil {
                    try document.setPrimaryAccountId(credentials.identity)
                }
                if makePrimary || document.activeAccountId == nil {
                    try document.setActiveAccountId(credentials.identity)
                }
            }
        } catch {
            // 状态提交失败时恢复该 identity，不触碰其他账号；
            // 恢复结果随 AccountImportError 返回，不依赖事后读属性。
            // 旧凭据存在时恢复旧凭据；新导入时清理刚写入的凭据，清理失败
            // 会留下孤立凭据（state 未引用），与删除路径的“凭据已丢失”
            // 不是同一回事。
            let recovery: AccountRecovery
            do {
                if let oldCredentials {
                    try await vault.save(oldCredentials)
                } else {
                    try await vault.remove(identity: credentials.identity)
                }
                recovery = .restored
                lastRecoveryFailureCode = nil
            } catch {
                recovery = .failed
                lastRecoveryFailureCode = "recovery_failed"
            }
            throw AccountImportError(underlying: error, recovery: recovery)
        }

        lastFailureCode = nil
        lastRecoveryFailureCode = nil
        let document = await repository.state()
        return summary(credentials, document: document)
    }

    func switchAccount(identity: String) async throws {
        await acquire()
        defer { release() }

        guard try await vault.load(identity: identity) != nil else {
            // Kotlin 缺凭据抛 missing_account，不带 definitive 参数（默认 false）。
            throw XmlyError.failure(
                code: .missingAccount,
                message: "请先登录该账号"
            )
        }
        let document = await repository.state()
        guard document.activeAccountId != identity else { return }
        try await repository.transaction {
            try $0.setActiveAccountId(identity)
        }
        lastFailureCode = nil
    }

    // 与 Kotlin setPrimaryAccount 一致：主账号与活动账号同时指向目标。
    func setPrimaryAccount(identity: String) async throws {
        await acquire()
        defer { release() }

        guard try await vault.load(identity: identity) != nil else {
            throw XmlyError.failure(
                code: .missingAccount,
                message: "请先登录该账号"
            )
        }
        try await repository.transaction { document in
            try document.setPrimaryAccountId(identity)
            try document.setActiveAccountId(identity)
        }
        lastFailureCode = nil
    }

    // 本地别名（Kotlin renameAccount）：官方 profile 读不到或用户自定义时使用，
    // summary 优先取 localName。
    func renameAccount(identity: String, nickname: String) async {
        await acquire()
        defer { release() }

        do {
            try await repository.transaction { document in
                var accounts = document.accounts
                var account = (accounts[identity] as? [String: Any]) ?? [:]
                account["localName"] = nickname.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                accounts[identity] = account
                try document.setAccounts(accounts)
            }
            lastFailureCode = nil
        } catch {
            record(error)
        }
    }

    /// 仅更新远端拉取的官方昵称（不覆盖用户主动设置的 localName）。
    func updateRemoteNickname(identity: String, nickname: String) async {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await acquire()
        defer { release() }

        do {
            try await repository.transaction { document in
                var accounts = document.accounts
                var account = (accounts[identity] as? [String: Any]) ?? [:]
                account["nickname"] = trimmed
                accounts[identity] = account
                try document.setAccounts(accounts)
            }
            lastFailureCode = nil
        } catch {
            record(error)
        }
    }

    /// 删除账号。本次跨存储补偿的结果随返回值返回（见 AccountRecovery），
    /// 不依赖事后读取 lastRecoveryFailureCode。
    @discardableResult
    func removeAccount(identity: String) async -> AccountRecovery {
        await acquire()
        defer { release() }
        lastRecoveryFailureCode = nil

        var recovery: AccountRecovery = .none
        do {
            let previous = try await vault.load(identity: identity)
            try await vault.remove(identity: identity)
            do {
                try await repository.transaction { document in
                    var accounts = document.accounts
                    accounts.removeValue(forKey: identity)
                    try document.setAccounts(accounts)

                    if accounts.isEmpty {
                        try document.setPrimaryAccountId(nil)
                        try document.setActiveAccountId(nil)
                    } else if document.primaryAccountId == identity {
                        // 回退目标取删除后剩余的 state.accounts（与 Kotlin
                        // removeAccount 一致）；iOS 侧取排序后首个，Kotlin
                        // 取 JSONObject 键序首个，两端均为“任一剩余账号”。
                        let next = accounts.keys.sorted().first
                        try document.setPrimaryAccountId(next)
                        // Kotlin：活动账号为空或为被删账号时跟进为 next；
                        // 活动账号为其他有效账号时保持不变。
                        if document.activeAccountId == identity
                            || document.activeAccountId == nil {
                            try document.setActiveAccountId(next)
                        }
                    } else if document.activeAccountId == identity {
                        // Kotlin 的 signOut 会把活动账号清空且不回退到 primary；
                        // 此处保持 null，与原端行为一致（下次导入或切换时再激活）。
                        try document.setActiveAccountId(nil)
                    }
                }
            } catch {
                // state 提交失败时恢复刚删的凭据；恢复结果随返回值返回。
                // previous 为 nil 时无凭据可恢复，recovery 保持 .none。
                if let previous {
                    do {
                        try await vault.save(previous)
                        recovery = .restored
                        lastRecoveryFailureCode = nil
                    } catch {
                        recovery = .failed
                        lastRecoveryFailureCode = "recovery_failed"
                    }
                }
                throw error
            }
            lastFailureCode = nil
            lastRecoveryFailureCode = nil
        } catch {
            record(error)
        }
        return recovery
    }

    func activeAccount() async -> AccountSummary? {
        await acquire()
        defer { release() }
        let document = await repository.state()
        return await loadSummary(document.activeAccountId, document: document)
    }

    func primaryAccount() async -> AccountSummary? {
        await acquire()
        defer { release() }
        let document = await repository.state()
        return await loadSummary(document.primaryAccountId, document: document)
    }

    func allAccounts() async -> [AccountSummary] {
        await acquire()
        defer { release() }

        let document = await repository.state()
        do {
            // 与 Kotlin accounts() 一致：以 state.accounts 为枚举源，再筛选
            // 有有效凭据的记录；孤立 Keychain 项（无状态记录）不列入，
            // 其恢复是独立流程（备份／迁移时处理）。
            var result: [AccountSummary] = []
            for identity in document.accounts.keys.sorted() {
                if let credentials = try await vault.load(identity: identity) {
                    result.append(summary(credentials, document: document))
                }
            }
            return result.sorted {
                if $0.primary != $1.primary { return $0.primary }
                if $0.active != $1.active { return $0.active }
                return $0.identity < $1.identity
            }
        } catch {
            record(error)
            return []
        }
    }

    func activeContext() async throws -> AccountContext {
        await acquire()
        defer { release() }

        let document = await repository.state()
        guard let identity = document.activeAccountId,
              let credentials = try await vault.load(identity: identity) else {
            throw XmlyError.failure(
                code: .loginRequired,
                message: "需要登录账号",
                definitive: true
            )
        }
        return AccountContext(credentials: credentials)
    }

    func updateQuota(identity: String, quota: Quota) async {
        await acquire()
        defer { release() }

        do {
            try await repository.transaction { document in
                var accounts = document.accounts
                guard var account = accounts[identity] as? [String: Any] else {
                    return
                }
                account["quota"] = quota.stateJSON
                accounts[identity] = account
                try document.setAccounts(accounts)
            }
            lastFailureCode = nil
        } catch {
            record(error)
        }
    }

    func setPaused(identity: String, paused: Bool) async {
        await acquire()
        defer { release() }

        do {
            try await repository.transaction { document in
                var accounts = document.accounts
                guard var account = accounts[identity] as? [String: Any] else {
                    return
                }
                account["rewardPaused"] = paused
                accounts[identity] = account
                try document.setAccounts(accounts)
            }
            lastFailureCode = nil
        } catch {
            record(error)
        }
    }

    // 登录用的设备标识：有活动账号时取其 deviceId，否则取安装标识。
    // 凭据读取失败（Keychain 暂不可访问）会抛错，不静默降级为安装标识：
    // 余额按设备区分，静默换身份会让登录拿到错误的设备额度。
    func deviceIdForLogin() async throws -> String {
        await acquire()
        defer { release() }

        do {
            let document = await repository.state()
            var credentials: Credentials?
            if let identity = document.activeAccountId {
                credentials = try await vault.load(identity: identity)
            }
            lastFailureCode = nil
            return await installDevice.deviceIdForLogin(credentials: credentials)
        } catch {
            record(error)
            throw error
        }
    }

    private func loadSummary(
        _ identity: String?,
        document: StateDocument
    ) async -> AccountSummary? {
        guard let identity else { return nil }
        do {
            guard let credentials = try await vault.load(identity: identity) else {
                return nil
            }
            return summary(credentials, document: document)
        } catch {
            record(error)
            return nil
        }
    }

    private func summary(
        _ credentials: Credentials,
        document: StateDocument
    ) -> AccountSummary {
        let account = document.accounts[credentials.identity] as? [String: Any] ?? [:]
        // 键名与 Kotlin AccountSummary 逐一对齐：deviceHint/rewardPaused/
        // quotaError/avatar/localName 优先于 nickname；空头像取 null；
        // 计数类字段按 org.json optInt 转换（数值字符串可解析）。
        let localName = account["localName"] as? String ?? ""
        let avatar = account["avatar"] as? String
        return AccountSummary(
            identity: credentials.identity,
            uid: credentials.uid,
            deviceHint: account["deviceHint"] as? String ?? "****",
            quota: Quota.fromState(account["quota"]),
            paused: account["rewardPaused"] as? Bool ?? false,
            primary: document.primaryAccountId == credentials.identity,
            active: document.activeAccountId == credentials.identity,
            quotaRejected: account["quotaError"] as? Bool ?? false,
            nickname: localName.isEmpty
                ? (account["nickname"] as? String ?? "") : localName,
            avatarUrl: avatar?.isEmpty == false ? avatar : nil,
            mobile: account["mobile"] as? String ?? "",
            followers: Self.nonnegativeInteger(account["followers"]),
            following: Self.nonnegativeInteger(account["following"]),
            subscriptionCount: Self.nonnegativeInteger(account["subscriptionCount"])
        )
    }

    // 与 Kotlin AppContainer.hint 一致：短于等于 4 位只显示占位，否则 "…" + 末 4 位。
    private static func deviceHint(for deviceId: String) -> String {
        deviceId.count <= 4 ? "****" : "…" + deviceId.suffix(4)
    }

    // 与 Kotlin AppContainer.maskMobile 一致：满 7 位取前 3 + **** + 末 4，
    // 不足 7 位原样保存。
    private static func maskMobile(_ mobile: String) -> String {
        mobile.count >= 7
            ? String(mobile.prefix(3)) + "****" + String(mobile.suffix(4))
            : mobile
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        // org.json optInt（默认 -1）+ takeIf { >= 0 }：数值字符串可解析。
        let result = xmlyJsonInt(value, default: -1)
        return result >= 0 ? result : nil
    }

    private func record(_ error: Error) {
        if let error = error as? StateError {
            lastFailureCode = error.code
        } else if let error = error as? XmlyError {
            lastFailureCode = error.code
        } else {
            lastFailureCode = "write_failed"
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        // 取消不会把等待者移出队列：被取消的任务恢复后仍会执行，
        // 调用方不应依赖取消来阻止一次已排队的账号写操作。
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
