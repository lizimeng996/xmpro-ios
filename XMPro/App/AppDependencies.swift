import Combine
import Foundation

@MainActor
final class AppDependencies: ObservableObject {
    typealias ClientFactory = @MainActor () async throws -> XmlyClientService
    typealias HistoryFactory = @MainActor (String) async throws -> any PlaybackHistory

    let http: any HTTPTransport
    let serverClock: ServerClock
    let stateRepository: StateRepository?
    let accountStore: AccountStore?
    let credentialsVault: CredentialsVault
    let installDevice: InstallDevice
    let initializationError: String?
    let bookmarkService: XmlyBookmarkService?
    let backupService: BackupService
    let accountCoordinator: AccountCoordinator?
    let commentsSession: CommentsSession
    let usageLedger: UsageLedger?
    let smartSkipScanner: SmartSkipScanner
    let themeStore: ThemeStore
    let loginService: XmlyLoginService

    @Published private(set) var playbackSession: PlaybackSession
    @Published private(set) var experienceService: XmlyExperienceService
    @Published private(set) var welfareService: XmlyWelfareService
    @Published private(set) var channelService: XmlyChannelService
    @Published private(set) var accountRevision = 0
    @Published private(set) var backupMessage: String?
    @Published var userPageUID: String?
    @Published var userPageError: XmlyError?
    @Published private(set) var subscribedAlbumIds: Set<String> = []
    @Published private(set) var favoritedTrackIds: Set<String> = []

    // 由平台宿主接 fileExporter/fileImporter；本层只传递 Data。
    var onExportBackup: (@MainActor (Data) -> Void)?
    var onImportBackup: (@MainActor () async throws -> Data)?

    private let clientFactory: ClientFactory
    private let historyFactory: HistoryFactory
    private var playbackStore: S4PlaybackStore
    private var importInProgress = false
    private var accountRefreshGeneration = 0
    private var subscriptionsSynced = false

    init(
        serverClock: ServerClock = .shared,
        http: (any HTTPTransport)? = nil,
        stateRepository: StateRepository? = nil,
        credentialsVault: CredentialsVault = CredentialsVault(),
        installDevice: InstallDevice = InstallDevice(),
        backupService: BackupService = BackupService(),
        clientFactory: ClientFactory? = nil,
        automaticallyRefreshAccounts: Bool = true
    ) {
        self.serverClock = serverClock
        let transport = http ?? XmlyHTTP(serverClock: serverClock)
        self.http = transport
        self.credentialsVault = credentialsVault
        self.installDevice = installDevice
        self.backupService = backupService

        let repository: StateRepository?
        let startupError: String?
        if let stateRepository {
            repository = stateRepository
            startupError = nil
        } else {
            do {
                guard let base = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    throw StateError.directory
                }
                repository = try StateRepository.open(
                    directory: base.appendingPathComponent("XMPro", isDirectory: true)
                )
                startupError = nil
            } catch {
                repository = nil
                startupError = "无法打开本地状态；请检查存储或恢复备份"
            }
        }
        self.stateRepository = repository
        initializationError = startupError

        let accounts = repository.map {
            AccountStore(
                repository: $0,
                vault: credentialsVault,
                installDevice: installDevice
            )
        }
        accountStore = accounts

        let defaultClientFactory: ClientFactory = {
            let context: AccountContext?
            if let accounts {
                do {
                    context = try await accounts.activeContext()
                } catch let error as XmlyError {
                    if error.code == XmlyError.Code.loginRequired.rawValue {
                        context = nil
                    } else {
                        throw error
                    }
                }
            } else {
                context = nil
            }
            return XmlyClientService(
                http: transport, accountContext: context, clock: serverClock
            )
        }
        let makeClient = clientFactory ?? defaultClientFactory
        self.clientFactory = makeClient

        let makeHistory: HistoryFactory = { identity in
            guard let repository else { throw StateError.directory }
            let document = await repository.state()
            guard document.accounts[identity] != nil,
                  let credentials = try await credentialsVault.load(identity: identity),
                  credentials.identity == identity else {
                throw XmlyError.failure(
                    code: .loginRequired,
                    message: "需要重新登录原播放账号",
                    definitive: true
                )
            }
            let client = XmlyClientService(
                http: transport,
                accountContext: AccountContext(credentials: credentials),
                clock: serverClock
            )
            return XmlyHistoryService(client: client, clock: serverClock)
        }
        historyFactory = makeHistory

        let underlying: any PlaybackStore
        if let repository {
            underlying = StatePlaybackStore(repository: repository)
        } else {
            underlying = UnavailablePlaybackStore()
        }
        let store = S4PlaybackStore(underlying: underlying)
        playbackStore = store
        let ledger = repository.map { UsageLedger(repository: $0) }
        usageLedger = ledger
        let scanner = SmartSkipScanner()
        smartSkipScanner = scanner
        themeStore = ThemeStore(repository: repository)
        loginService = XmlyLoginService(
            transport: URLSessionPassportTransport(),
            clock: serverClock
        )

        let playback = PlaybackSession(
            engine: PlaybackEngine(),
            store: store,
            clock: SystemPlaybackClock(serverClock: serverClock),
            clientFactory: { try await makeClient() },
            historyFactory: { try await makeHistory($0) }
        )
        playback.usageLedger = ledger
        playback.smartSkipScanner = scanner
        playbackSession = playback

        if let repository, let accounts {
            bookmarkService = XmlyBookmarkService(
                repository: repository, accountStore: accounts
            )
            accountCoordinator = AccountCoordinator(
                accountStore: accounts,
                repository: repository,
                vault: credentialsVault,
                playbackSession: playback
            )
        } else {
            bookmarkService = nil
            accountCoordinator = nil
        }

        let anonymous = XmlyClientService(
            http: transport, accountContext: nil, clock: serverClock
        )
        commentsSession = CommentsSession(
            client: anonymous, clientFactory: makeClient
        )
        experienceService = XmlyExperienceService(client: anonymous)
        welfareService = XmlyWelfareService(
            http: transport, accountContext: nil, clock: serverClock
        )
        channelService = XmlyChannelService(
            client: anonymous, repository: repository, clock: serverClock
        )

        accountCoordinator?.onAccountChange = { [weak self] in
            await self?.refreshAccountServices()
        }
        if automaticallyRefreshAccounts {
            Task { [weak self] in
                await self?.refreshAccountServices()
            }
        }
    }

    func makeCurrentClient() async throws -> XmlyClientService {
        try await clientFactory()
    }

    func makeCurrentHistoryService() async throws -> XmlyHistoryService {
        let client = try await clientFactory()
        guard client.hasAccount else {
            throw XmlyError.failure(
                code: .loginRequired,
                message: "登录后可查看收听历史",
                definitive: true
            )
        }
        return XmlyHistoryService(client: client, clock: serverClock)
    }

    func refreshAccountServices() async {
        accountRefreshGeneration &+= 1
        let generation = accountRefreshGeneration
        commentsSession.reset()
        userPageUID = nil
        subscribedAlbumIds = []
        favoritedTrackIds = []
        subscriptionsSynced = false
        do {
            let client = try await clientFactory()
            let activeContext: AccountContext?
            if let accountStore {
                activeContext = try? await accountStore.activeContext()
            } else {
                activeContext = nil
            }
            guard generation == accountRefreshGeneration else { return }
            experienceService = XmlyExperienceService(client: client)
            welfareService = XmlyWelfareService(
                http: http, accountContext: activeContext, clock: serverClock
            )
            channelService = XmlyChannelService(
                client: client, repository: stateRepository, clock: serverClock
            )
        } catch {
            guard generation == accountRefreshGeneration else { return }
            let anonymous = XmlyClientService(
                http: http, accountContext: nil, clock: serverClock
            )
            experienceService = XmlyExperienceService(client: anonymous)
            welfareService = XmlyWelfareService(
                http: http, accountContext: nil, clock: serverClock
            )
            channelService = XmlyChannelService(
                client: anonymous, repository: stateRepository, clock: serverClock
            )
        }
        accountRevision &+= 1
    }

    private func normalizedAlbumKey(_ raw: String) -> String {
        (try? xmlyIdentifier(raw)) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTrackKey(_ raw: String) -> String {
        (try? xmlyIdentifier(raw)) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAlbumSubscribed(_ albumId: String) -> Bool {
        subscribedAlbumIds.contains(normalizedAlbumKey(albumId))
    }

    func setAlbumSubscribed(_ albumId: String, subscribed: Bool) {
        let key = normalizedAlbumKey(albumId)
        guard !key.isEmpty else { return }
        if subscribed {
            subscribedAlbumIds.insert(key)
        } else {
            subscribedAlbumIds.remove(key)
        }
    }

    func recordSubscriptions(_ items: [SubscriptionItem], replace: Bool = false) {
        let keys = Set(items.map { normalizedAlbumKey($0.album.id) }.filter { !$0.isEmpty })
        if replace {
            subscribedAlbumIds = keys
        } else {
            subscribedAlbumIds.formUnion(keys)
        }
        subscriptionsSynced = true
    }

    func syncSubscriptionsIfNeeded() async {
        guard !subscriptionsSynced else { return }
        var collected: Set<String> = []
        var page = 1
        // 拉取前 5 页订阅列表（最多 150 个）以初始化订阅状态
        while page <= 5 {
            guard let result = try? await experienceService.subscriptions(page: page, pageSize: 30) else {
                break
            }
            for item in result.items {
                let key = normalizedAlbumKey(item.album.id)
                if !key.isEmpty { collected.insert(key) }
            }
            if !result.hasMore { break }
            page += 1
        }
        if !collected.isEmpty || page > 1 {
            subscribedAlbumIds.formUnion(collected)
            subscriptionsSynced = true
        }
    }

    func isTrackFavorited(_ trackId: String) -> Bool {
        favoritedTrackIds.contains(normalizedTrackKey(trackId))
    }

    func setTrackFavorited(_ trackId: String, favorited: Bool) {
        let key = normalizedTrackKey(trackId)
        guard !key.isEmpty else { return }
        if favorited {
            favoritedTrackIds.insert(key)
        } else {
            favoritedTrackIds.remove(key)
        }
    }

    func recordFavorites(_ tracks: [Track]) {
        for track in tracks {
            let key = normalizedTrackKey(track.id)
            if !key.isEmpty { favoritedTrackIds.insert(key) }
        }
    }

    func openUser(track: Track) {
        let raw = track.raw.compactMapValues { $0 }
        let containers = [
            raw,
            raw["anchorInfo"] as? [String: Any] ?? [:],
            raw["userInfo"] as? [String: Any] ?? [:]
        ]
        for container in containers {
            for key in ["uid", "anchorUid", "anchorId", "userId"] {
                guard let value = container[key] else { continue }
                let text = B1JSON.text(value)
                if let uid = try? xmlyIdentifier(text), !uid.isEmpty {
                    userPageUID = uid
                    return
                }
            }
        }
        userPageError = .failure(
            code: .invalidId,
            message: "当前声音未提供主播编号，暂时无法打开主播页",
            definitive: true
        )
    }

    func exportBackup(includeCredentials: Bool) async throws -> Data {
        guard let repository = stateRepository else {
            throw XmlyError.failure(code: .uncertain, message: "本地状态不可用")
        }
        guard let deliver = onExportBackup else {
            throw XmlyError.failure(
                code: .uncertain,
                message: "备份导出未接线：宿主未提供文件保存入口"
            )
        }
        let document = await repository.state()
        let data = try await backupService.export(
            state: document.json,
            includeCredentials: includeCredentials,
            vault: credentialsVault
        )
        deliver(data)
        return data
    }

    func importBackup(data: Data) async throws -> BackupImportResult {
        guard !importInProgress else {
            throw XmlyError.failure(code: .uncertain, message: "正在恢复备份，请稍候")
        }
        guard let repository = stateRepository else {
            throw XmlyError.failure(code: .uncertain, message: "本地状态不可用")
        }

        // 先校验，损坏备份不会停止播放或触发旧 session 的进度写入。
        try backupService.validate(data: data)
        importInProgress = true
        defer { importInProgress = false }

        playbackSession.stop()
        // 阻止旧 session 的异步 persist 在导入完成后覆盖新状态。
        await playbackStore.disableAndDrain()
        commentsSession.reset()

        do {
            let result = try await backupService.import(
                data: data, repository: repository, vault: credentialsVault
            )
            backupMessage = "已恢复备份（\(result.accounts) 个账号）"
            await rebuildPlayback()
            return result
        } catch {
            backupMessage = s4Error(error, fallback: "恢复备份失败，请重试").message
            // vault 部分保存失败时，state 已替换；也必须回读新状态。
            await rebuildPlayback()
            throw error
        }
    }

    private func rebuildPlayback() async {
        guard let repository = stateRepository else { return }
        let store = S4PlaybackStore(
            underlying: StatePlaybackStore(repository: repository)
        )
        playbackStore = store
        let makeClient = clientFactory
        let makeHistory = historyFactory
        let session = PlaybackSession(
            engine: PlaybackEngine(),
            store: store,
            clock: SystemPlaybackClock(serverClock: serverClock),
            clientFactory: { try await makeClient() },
            historyFactory: { try await makeHistory($0) }
        )
        session.usageLedger = usageLedger
        session.smartSkipScanner = smartSkipScanner
        playbackSession = session
        accountCoordinator?.playbackSession = session
        await session.prepare()
        await refreshAccountServices()
    }
}

@MainActor
private final class S4PlaybackStore: PlaybackStore {
    private let underlying: any PlaybackStore
    private var enabled = true
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(underlying: any PlaybackStore) {
        self.underlying = underlying
    }

    func load() async throws -> PlaybackStoredState {
        try await underlying.load()
    }

    func save(_ state: PlaybackStoredState) async throws {
        guard enabled else { return }
        inFlight += 1
        defer {
            inFlight -= 1
            if inFlight == 0 {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }
        }
        try await underlying.save(state)
    }

    func disableAndDrain() async {
        enabled = false
        guard inFlight > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
