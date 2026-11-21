import Foundation

typealias AccountRecovery = AccountStore.AccountRecovery

@MainActor
final class AccountCoordinator {
    let accountStore: AccountStore
    let vault: CredentialsVault
    var playbackSession: PlaybackSession?
    var onAccountChange: (@MainActor () async -> Void)?

    private let repository: StateRepository
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var lastError: XmlyError?

    init(
        accountStore: AccountStore,
        repository: StateRepository,
        vault: CredentialsVault,
        playbackSession: PlaybackSession? = nil
    ) {
        self.accountStore = accountStore
        self.repository = repository
        self.vault = vault
        self.playbackSession = playbackSession
    }

    func exportCookie(identity: String) async throws -> String {
        guard let credentials = try await vault.load(identity: identity) else {
            throw XmlyError.failure(
                code: .missingAccount,
                message: "该账号的登录信息已失效，请重新登录"
            )
        }
        return credentials.cookie
    }

    func switchAccount(identity: String) async throws {
        await acquire()
        defer { release() }
        lastError = nil
        playbackSession?.stop()
        do {
            try await accountStore.switchAccount(identity: identity)
            await onAccountChange?()
        } catch {
            lastError = s4Error(error, fallback: "切换账号失败，请重试")
            throw lastError!
        }
    }

    func setPrimaryAccount(identity: String) async throws {
        await acquire()
        defer { release() }
        lastError = nil
        // AccountStore 的主账号操作也会切换活动账号。
        playbackSession?.stop()
        do {
            try await accountStore.setPrimaryAccount(identity: identity)
            await onAccountChange?()
        } catch {
            lastError = s4Error(error, fallback: "设置主账号失败，请重试")
            throw lastError!
        }
    }

    func signOut(identity: String) async {
        await acquire()
        defer { release() }
        lastError = nil
        let state = await repository.state()
        if state.activeAccountId == identity {
            playbackSession?.stop()
        }
        do {
            try await vault.remove(identity: identity)
            try await repository.transaction { document in
                if document.activeAccountId == identity {
                    try document.setActiveAccountId(nil)
                }
            }
        } catch {
            lastError = s4Error(error, fallback: "退出账号失败，请重试")
        }
        await onAccountChange?()
    }

    @discardableResult
    func removeAccount(identity: String) async -> AccountRecovery {
        await acquire()
        defer { release() }
        lastError = nil
        let state = await repository.state()
        if state.activeAccountId == identity {
            playbackSession?.stop()
        }

        let recovery = await accountStore.removeAccount(identity: identity)
        if recovery == .failed {
            lastError = .failure(
                code: .invalidCredentials,
                message: "账号清理未完成，请重新导入该账号的登录信息"
            )
        } else if await accountStore.lastFailureCode != nil {
            lastError = .failure(
                code: .uncertain,
                message: "删除账号失败，请重试"
            )
        }
        await onAccountChange?()
        return recovery
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
