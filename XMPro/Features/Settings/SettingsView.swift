import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct BackupJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum SettingsRoute: Hashable {
    case accountQuota
    case playback
    case channels
    case appearance
    case backup
    case about
    case following(String)
    case fans(String)
    case subscriptions
    case favorites
}

/// 「我的」主页面：大标题 + InsetGrouped 原生设置风格 + 个人资料与听时概览
@MainActor
struct SettingsView: View {
    var onOpenPlayer: (() -> Void)? = nil
    @EnvironmentObject private var dependencies: AppDependencies

    var body: some View {
        ProfileHomeContentView(
            dependencies: dependencies,
            session: dependencies.playbackSession,
            themeStore: dependencies.themeStore,
            onOpenPlayer: onOpenPlayer
        )
    }
}

@MainActor
private struct ProfileHomeContentView: View {
    @ObservedObject var dependencies: AppDependencies
    @ObservedObject var session: PlaybackSession
    @ObservedObject var themeStore: ThemeStore
    var onOpenPlayer: (() -> Void)? = nil
    @Environment(\.xmPalette) private var palette

    @State private var activeAccount: AccountSummary?
    @State private var profile: UserProfile?
    @State private var favoriteCount: Int = 0
    @State private var favoriteHasMore = false
    @State private var quota: Quota?
    @State private var busy = false
    @State private var statusBanner: String?
    @State private var loginMode: LoginView.Mode = .sms
    @State private var loginOpen = false
    @State private var selectedStatRoute: SettingsRoute?
    @State private var statRouteOpen = false

    private var autoClaimOn: Bool {
        !(activeAccount?.paused ?? false)
    }

    var body: some View {
        List {
            profileSection

            if activeAccount != nil {
                quotaSection
            }

            Section {
                settingsLink(
                    route: .accountQuota,
                    icon: "person.fill",
                    color: palette.accent,
                    title: "账号与听时",
                    value: activeAccount == nil ? "未登录" : nil
                )
                settingsLink(
                    route: .playback,
                    icon: "play.fill",
                    color: .indigo,
                    title: "播放设置",
                    value: XMDesign.qualityLabel(session.settings.quality)
                )
                settingsLink(
                    route: .channels,
                    icon: "square.grid.2x2.fill",
                    color: .orange,
                    title: "频道管理"
                )
                settingsLink(
                    route: .appearance,
                    icon: "paintpalette.fill",
                    color: .pink,
                    title: "外观",
                    value: themeStore.theme.displayName
                )
            }

            Section {
                settingsLink(
                    route: .backup,
                    icon: "arrow.down.doc.fill",
                    color: .teal,
                    title: "备份与恢复"
                )
                settingsLink(
                    route: .about,
                    icon: "info.circle.fill",
                    color: .gray,
                    title: "关于"
                )
            }
        }
        .listStyle(.insetGrouped)
        .xmPageBackground()
        .xmToast($statusBanner)
        .refreshable {
            await loadOverview(fetchRemoteProfile: true)
        }
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: SettingsRoute.self) { route in
            destinationView(for: route)
        }
        .navigationDestination(isPresented: $statRouteOpen) {
            if let selectedStatRoute {
                destinationView(for: selectedStatRoute)
            }
        }
        .navigationDestination(isPresented: $loginOpen) {
            LoginView(initialMode: loginMode) { successMessage in
                loginOpen = false
                statusBanner = successMessage
                Task { await loadOverview(fetchRemoteProfile: true) }
            }
            .id(loginMode)
        }
        .task(id: dependencies.accountRevision) {
            await session.prepare()
            await loadOverview(fetchRemoteProfile: false)
        }
        .onAppear {
            Task { await loadOverview(fetchRemoteProfile: false) }
        }
    }

    private var profileSection: some View {
        Section {
            if let account = activeAccount {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        XMArtwork(
                            url: profile?.avatarUrl ?? account.avatarUrl,
                            cornerRadius: 30,
                            symbol: "person.fill"
                        )
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            let name = account.nickname.isEmpty
                                ? (profile?.nickname.isEmpty == false ? profile!.nickname : "听友\(account.uid)")
                                : account.nickname
                            Text(name)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text("UID \(account.uid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if account.primary {
                                    XMTag(text: "主账号")
                                }
                            }
                        }
                        Spacer()
                        if busy { ProgressView() }
                    }

                    HStack(spacing: 0) {
                        statButton(
                            valueText: "\(profile?.following ?? 0)",
                            label: "关注",
                            route: .following(account.uid)
                        )
                        Divider().frame(height: 22)
                        statButton(
                            valueText: "\(profile?.followers ?? 0)",
                            label: "粉丝",
                            route: .fans(account.uid)
                        )
                        Divider().frame(height: 22)
                        statButton(
                            valueText: "\(profile?.subscriptions ?? 0)",
                            label: "订阅",
                            route: .subscriptions
                        )
                        Divider().frame(height: 22)
                        statButton(
                            valueText: favoriteHasMore ? "\(favoriteCount)+" : "\(favoriteCount)",
                            label: "收藏",
                            route: .favorites
                        )
                    }
                    .padding(.vertical, 8)
                    .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 44))
                            .foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("尚未登录账号")
                                .font(.headline)
                            Text("登录后可同步书单、听时福利与历史进度")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    HStack(spacing: 10) {
                        Button {
                            loginMode = .sms
                            loginOpen = true
                        } label: {
                            Text("短信登录")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .xmProminentButton()

                        Button {
                            loginMode = .credential
                            loginOpen = true
                        } label: {
                            Text("导入 Cookie")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                        }
                        .xmGlassButton()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var quotaSection: some View {
        Section("本机可用听时") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(quotaValueText)
                        .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(currentQuota == nil ? .secondary : .primary)
                    Spacer()
                    if let checked = quotaCheckedText {
                        Text("核验于 \(checked)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await queryQuota() }
                    } label: {
                        Text("查询时长")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .xmGlassButton()
                    .disabled(busy)

                    Button {
                        Task { await claimOnce() }
                    } label: {
                        Text("单次领取")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .xmProminentButton()
                    .disabled(busy)
                }
            }
            .padding(.vertical, 4)

            Toggle("自动领取听时", isOn: Binding(
                get: { autoClaimOn },
                set: { _ in Task { await toggleAutoClaim() } }
            ))
            .disabled(busy)
        }
    }

    private func settingsLink(
        route: SettingsRoute,
        icon: String,
        color: Color,
        title: String,
        value: String? = nil
    ) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 12) {
                XMIconBadge(systemImage: icon, color: color)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func destinationView(for route: SettingsRoute) -> some View {
        switch route {
        case .accountQuota:
            AccountAndQuotaSettingsView(
                dependencies: dependencies,
                themeStore: themeStore
            )
        case .playback:
            PlaybackPreferencesView(
                session: dependencies.playbackSession,
                themeStore: themeStore
            )
        case .channels:
            ChannelsView()
        case .appearance:
            AppearanceSettingsView(themeStore: themeStore)
        case .backup:
            BackupSettingsView(dependencies: dependencies)
        case .about:
            AboutSettingsView()
        case .following(let uid):
            SocialUserListView(uid: uid, kind: .following, service: dependencies.experienceService)
        case .fans(let uid):
            SocialUserListView(uid: uid, kind: .fans, service: dependencies.experienceService)
        case .subscriptions:
            ShelfView(
                initialTab: .subscriptions,
                navigationTitle: "我的订阅",
                compactTitle: true,
                onOpenPlayer: onOpenPlayer
            )
        case .favorites:
            ShelfView(
                initialTab: .favorites,
                navigationTitle: "我的收藏",
                compactTitle: true,
                onOpenPlayer: onOpenPlayer
            )
        }
    }

    private func statButton(valueText: String, label: String, route: SettingsRoute) -> some View {
        Button {
            selectedStatRoute = route
            statRouteOpen = true
        } label: {
            VStack(spacing: 2) {
                Text(valueText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private var currentQuota: Quota? {
        quota ?? activeAccount?.quota
    }

    private var quotaValueText: String {
        if let q = currentQuota {
            return XMDesign.formatShortDuration(q.remainingSeconds)
        }
        return "尚未查询"
    }

    private var quotaCheckedText: String? {
        guard let q = currentQuota else { return nil }
        let date = Date(timeIntervalSince1970: Double(q.checkedAtMillis) / 1_000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func loadOverview(fetchRemoteProfile: Bool) async {
        activeAccount = await dependencies.accountStore?.activeAccount()
        quota = await dependencies.usageLedger?.cachedDeviceQuota() ?? activeAccount?.quota
        guard activeAccount != nil else {
            profile = nil
            favoriteCount = 0
            favoriteHasMore = false
            return
        }
        if fetchRemoteProfile || profile == nil {
            if let loaded = try? await dependencies.experienceService.profile() {
                profile = loaded
            }
            if let favs = try? await dependencies.experienceService.favorites(page: 1, pageSize: 30) {
                favoriteCount = favs.items.count
                favoriteHasMore = favs.hasMore
            }
        }
    }

    private func queryQuota() async {
        guard let account = activeAccount else { return }
        busy = true
        defer { busy = false }
        do {
            let client = try await dependencies.makeCurrentClient()
            if let ledger = dependencies.usageLedger {
                quota = try await ledger.refreshQuota(identity: account.identity, client: client)
            } else {
                quota = try await client.quota()
            }
            if let q = quota {
                await dependencies.accountStore?.updateQuota(identity: account.identity, quota: q)
            }
            statusBanner = "已刷新本机可用听时"
        } catch {
            statusBanner = s4Error(error, fallback: "查询听时失败").message
        }
    }

    private func claimOnce() async {
        guard activeAccount != nil else { return }
        busy = true
        defer { busy = false }
        do {
            let tasks = (try? await dependencies.welfareService.queryTasks())?.tasks ?? []
            let task = tasks.first(where: \.claimable) ?? tasks.first
            let result = try await dependencies.welfareService.claim(task: task)
            statusBanner = result.message
            if result.success {
                await queryQuota()
            }
        } catch {
            statusBanner = s4Error(error, fallback: "领取听时失败").message
        }
    }

    private func toggleAutoClaim() async {
        guard let account = activeAccount, let store = dependencies.accountStore else { return }
        let nextPaused = !account.paused
        await store.setPaused(identity: account.identity, paused: nextPaused)
        activeAccount = await store.activeAccount()
        statusBanner = nextPaused ? "已关闭自动领取听时" : "已开启自动领取听时"
    }
}

// MARK: - 1. 账号与听时

@MainActor
private struct AccountAndQuotaSettingsView: View {
    @ObservedObject var dependencies: AppDependencies
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.xmPalette) private var palette

    @State private var accounts: [AccountSummary] = []
    @State private var activeAccount: AccountSummary?
    @State private var renameAlertOpen = false
    @State private var draftNickname = ""
    @State private var exportedCookie: String?
    @State private var deletingAccount: AccountSummary?
    @State private var busy = false
    @State private var message: String?
    @State private var loginMode: LoginView.Mode = .sms
    @State private var loginOpen = false

    var body: some View {
        List {
            Section("账号管理") {
                Button {
                    draftNickname = activeAccount?.nickname ?? ""
                    renameAlertOpen = true
                } label: {
                    rowLabel(title: "修改账号名", subtitle: "同步失败时可自定义显示名称")
                }
                .disabled(activeAccount == nil)

                Button {
                    Task { await syncProfile() }
                } label: {
                    rowLabel(title: "同步账号资料", subtitle: "从喜马拉雅拉取昵称、头像与关注粉丝数")
                }
                .disabled(activeAccount == nil || busy)

                Button {
                    Task { await copyCookie() }
                } label: {
                    rowLabel(title: "复制登录信息", subtitle: "导出本账号 Cookie 供其他设备导入")
                }
                .disabled(activeAccount == nil || busy)

                Button {
                    loginMode = .sms
                    loginOpen = true
                } label: {
                    HStack {
                        rowLabel(title: "短信登录新账号", subtitle: "手机号 + 安全验证")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                Button {
                    loginMode = .credential
                    loginOpen = true
                } label: {
                    HStack {
                        rowLabel(title: "添加 Cookie 账号", subtitle: "粘贴极速版 Cookie 或登录信息 JSON")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }

                if activeAccount != nil {
                    Button(role: .destructive) {
                        Task { await signOutActive() }
                    } label: {
                        Text("退出当前账号")
                    }
                    .disabled(busy)
                }
            }

            if let exportedCookie {
                Section("导出的 Cookie") {
                    ShareLink(item: exportedCookie) {
                        Label("系统分享 Cookie", systemImage: "square.and.arrow.up")
                    }
                    Button("清除导出缓存", role: .destructive) {
                        self.exportedCookie = nil
                    }
                }
            }

            if accounts.count > 1 {
                Section("已保存账号（\(accounts.count)）") {
                    ForEach(accounts, id: \.identity) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.nickname.isEmpty ? "听友\(account.uid)" : account.nickname)
                                    .font(.body.weight(.medium))
                                Text("UID \(account.uid)\(account.active ? " · 当前" : "")\(account.primary ? " · 主账号" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu("操作") {
                                if !account.active {
                                    Button("切换至此账号") {
                                        Task { await switchTo(account) }
                                    }
                                }
                                if !account.primary {
                                    Button("设为主账号") {
                                        Task { await setPrimary(account) }
                                    }
                                }
                                Button("删除账号", role: .destructive) {
                                    deletingAccount = account
                                }
                            }
                            .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }

            Section("听时") {
                Toggle(isOn: Binding(
                    get: { !(activeAccount?.paused ?? false) },
                    set: { enabled in
                        Task { await setAutoClaim(enabled: enabled) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动领取听时")
                        Text("前台低水位自动领取可用听时")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(activeAccount == nil)

                NavigationLink {
                    WelfareView()
                } label: {
                    rowLabel(title: "听时账本与福利任务", subtitle: "查看累计听时、待上报记录与任务列表")
                }
            }
        }
        .listStyle(.insetGrouped)
        .xmPageBackground()
        .xmToast($message)
        .navigationTitle("账号与听时")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $loginOpen) {
            LoginView(initialMode: loginMode) { successMessage in
                loginOpen = false
                message = successMessage
                Task { await reload() }
            }
            .id(loginMode)
        }
        .task(id: dependencies.accountRevision) {
            await reload()
        }
        .alert("修改账号名", isPresented: $renameAlertOpen) {
            TextField("输入自定义显示名称", text: $draftNickname)
            Button("保存") { Task { await saveNickname() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "确认删除该账号及其登录信息？",
            isPresented: Binding(
                get: { deletingAccount != nil },
                set: { if !$0 { deletingAccount = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let acc = deletingAccount {
                Button("删除账号", role: .destructive) {
                    deletingAccount = nil
                    Task { await remove(acc) }
                }
            }
            Button("取消", role: .cancel) { deletingAccount = nil }
        }
    }

    private func rowLabel(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        accounts = await dependencies.accountStore?.allAccounts() ?? []
        activeAccount = await dependencies.accountStore?.activeAccount()
    }

    private func saveNickname() async {
        guard let acc = activeAccount, let store = dependencies.accountStore else { return }
        let trimmed = draftNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.renameAccount(identity: acc.identity, nickname: trimmed)
        await dependencies.refreshAccountServices()
        await reload()
        message = "已更新账号显示名称"
    }

    private func syncProfile() async {
        guard let acc = activeAccount, let store = dependencies.accountStore else { return }
        busy = true
        defer { busy = false }
        do {
            let prof = try await dependencies.experienceService.profile()
            if !prof.nickname.isEmpty {
                await store.updateRemoteNickname(identity: acc.identity, nickname: prof.nickname)
            }
            await dependencies.refreshAccountServices()
            await reload()
            message = "已同步账号资料（\(prof.nickname.isEmpty ? acc.uid : prof.nickname)）"
        } catch {
            message = s4Error(error, fallback: "同步账号资料失败").message
        }
    }

    private func copyCookie() async {
        guard let acc = activeAccount, let coordinator = dependencies.accountCoordinator else { return }
        busy = true
        defer { busy = false }
        do {
            let cookie = try await coordinator.exportCookie(identity: acc.identity)
            UIPasteboard.general.string = cookie
            exportedCookie = cookie
            message = "登录 Cookie 已复制到剪贴板"
        } catch {
            message = s4Error(error, fallback: "导出登录信息失败").message
        }
    }

    private func signOutActive() async {
        guard let acc = activeAccount, let coordinator = dependencies.accountCoordinator else { return }
        busy = true
        defer { busy = false }
        await coordinator.signOut(identity: acc.identity)
        await reload()
        message = coordinator.lastError?.message ?? "已退出当前账号"
    }

    private func switchTo(_ account: AccountSummary) async {
        guard let coordinator = dependencies.accountCoordinator else { return }
        do {
            try await coordinator.switchAccount(identity: account.identity)
            await reload()
            message = "已切换账号"
        } catch {
            message = s4Error(error, fallback: "切换账号失败").message
        }
    }

    private func setPrimary(_ account: AccountSummary) async {
        guard let coordinator = dependencies.accountCoordinator else { return }
        do {
            try await coordinator.setPrimaryAccount(identity: account.identity)
            await reload()
            message = "已设为主账号"
        } catch {
            message = s4Error(error, fallback: "设置主账号失败").message
        }
    }

    private func remove(_ account: AccountSummary) async {
        guard let coordinator = dependencies.accountCoordinator else { return }
        _ = await coordinator.removeAccount(identity: account.identity)
        await reload()
        message = coordinator.lastError?.message ?? "已删除账号"
    }

    private func setAutoClaim(enabled: Bool) async {
        guard let acc = activeAccount, let store = dependencies.accountStore else { return }
        await store.setPaused(identity: acc.identity, paused: !enabled)
        await reload()
        message = enabled ? "已开启自动领取听时" : "已关闭自动领取听时"
    }
}

// MARK: - 2. 播放设置

@MainActor
private struct PlaybackPreferencesView: View {
    @ObservedObject var session: PlaybackSession
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.xmPalette) private var palette

    private let qualities: [(String, String)] = [
        ("自动", "auto"),
        ("高清", "m4a_128"),
        ("标准", "m4a_64"),
        ("省流", "mp3_32"),
        ("流畅", "m4a_24")
    ]

    var body: some View {
        Form {
            Section {
                Picker("音质偏好", selection: Binding(
                    get: { session.settings.quality },
                    set: { session.setQuality($0) }
                )) {
                    ForEach(qualities, id: \.1) { title, code in
                        Text(title).tag(code)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("音质")
            } footer: {
                Text("高清优先使用 AAC 128k；会员或听时权限不足时自动回落到可用码率。")
            }

            Section {
                Picker("音效预设", selection: Binding(
                    get: { themeStore.soundEffect },
                    set: { preset in
                        Task { await themeStore.selectSoundEffect(preset) }
                    }
                )) {
                    ForEach(SoundEffectPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("音效")
            } footer: {
                Text("音效偏好会自动保存，在播放器界面实时显示当前档位。")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { session.settings.skipTrim },
                    set: { enabled in
                        session.setSkipTrim(
                            enabled: enabled,
                            intro: session.settings.introPermille,
                            outro: session.settings.outroPermille,
                            mode: "manual"
                        )
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跳过头尾")
                        Text("按设定比例自动跳过单集片头与片尾")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if session.settings.skipTrim {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("跳过开头") {
                            Text(session.skipTrimPercentLabel(permille: session.settings.introPermille))
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(session.settings.introPermille) },
                                set: {
                                    session.setSkipTrim(
                                        enabled: true,
                                        intro: Int($0.rounded()),
                                        outro: session.settings.outroPermille,
                                        mode: "manual"
                                    )
                                }
                            ),
                            in: 0...200,
                            step: 5
                        )
                        .tint(palette.accent)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("跳过结尾") {
                            Text(session.skipTrimPercentLabel(permille: session.settings.outroPermille))
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(
                                get: { Double(session.settings.outroPermille) },
                                set: {
                                    session.setSkipTrim(
                                        enabled: true,
                                        intro: session.settings.introPermille,
                                        outro: Int($0.rounded()),
                                        mode: "manual"
                                    )
                                }
                            ),
                            in: 0...200,
                            step: 5
                        )
                        .tint(palette.accent)
                    }
                }
            } header: {
                Text("跳过头尾")
            }
        }
        .xmPageBackground()
        .navigationTitle("播放设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            session.migrateLegacySmartSkipIfNeeded()
        }
    }
}

// MARK: - 3. 外观

@MainActor
private struct AppearanceSettingsView: View {
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.xmPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("选择界面主题，所有页面与播放器控制层会即时适配。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AppTheme.allCases) { item in
                        themePreviewCard(item)
                    }
                }
            }
            .padding(XMMetrics.pagePadding)
        }
        .xmPageBackground()
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func themePreviewCard(_ item: AppTheme) -> some View {
        let selected = themeStore.theme == item
        let previewScheme: ColorScheme = item.preferredColorScheme ?? colorScheme
        let sample = XMPalette(theme: item, colorScheme: previewScheme)

        return Button {
            Task {
                await themeStore.select(item)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // 迷你界面预览色板
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(sample.accent)
                            .frame(width: 28, height: 10)
                        Spacer()
                        Circle()
                            .fill(sample.accent.opacity(0.25))
                            .frame(width: 14, height: 14)
                    }
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(sample.surface)
                        .frame(height: 36)
                        .overlay(
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(sample.accent.opacity(0.3))
                                    .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Capsule().fill(sample.isDark ? Color.white.opacity(0.75) : Color.black.opacity(0.65)).frame(width: 44, height: 5)
                                    Capsule().fill(sample.isDark ? Color.white.opacity(0.3) : Color.black.opacity(0.25)).frame(width: 28, height: 4)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 7)
                        )
                }
                .padding(10)
                .background(sample.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(sample.separator, lineWidth: 0.5)
                )

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .padding(12)
            .xmCard(cornerRadius: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? palette.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.xmPressable)
    }
}

// MARK: - 4. 备份与恢复

@MainActor
private struct BackupSettingsView: View {
    @ObservedObject var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var includeCredentials = false
    @State private var exportDocument: BackupJSONDocument?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("导出时包含账号登录信息", isOn: $includeCredentials)
            } header: {
                Text("导出选项")
            } footer: {
                Text("包含登录信息的备份为明文 JSON，请妥善保管；支持与 Android 版 XMPro 双向导入恢复。")
            }

            Section {
                Button {
                    Task { await startExport() }
                } label: {
                    Label("导出备份到文件", systemImage: "square.and.arrow.up")
                }
                .disabled(busy)

                Button {
                    if let select = dependencies.onImportBackup {
                        Task { await runImport(select) }
                    } else {
                        showingImporter = true
                    }
                } label: {
                    Label("从文件导入并恢复备份", systemImage: "square.and.arrow.down")
                }
                .disabled(busy)
            }
        }
        .xmPageBackground()
        .xmToast($message)
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "xmpro-backup"
        ) { result in
            exportDocument = nil
            switch result {
            case .success:
                message = "备份文件已导出"
            case let .failure(err):
                message = s4Error(err, fallback: "导出备份取消或失败").message
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    await runImport {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        return try Data(contentsOf: url)
                    }
                }
            case let .failure(err):
                message = s4Error(err, fallback: "读取备份文件失败").message
            }
        }
    }

    private func startExport() async {
        guard let repository = dependencies.stateRepository else {
            message = "本地状态不可用"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let document = await repository.state()
            let data = try await dependencies.backupService.export(
                state: document.json,
                includeCredentials: includeCredentials,
                vault: dependencies.credentialsVault
            )
            if let deliver = dependencies.onExportBackup {
                deliver(data)
                message = "已生成备份（\(data.count) 字节）"
            } else {
                exportDocument = BackupJSONDocument(data: data)
                showingExporter = true
            }
        } catch {
            message = s4Error(error, fallback: "导出备份失败").message
        }
    }

    private func runImport(_ provider: () async throws -> Data) async {
        busy = true
        defer { busy = false }
        do {
            let data = try await provider()
            let result = try await dependencies.importBackup(data: data)
            message = "已恢复备份（\(result.accounts) 个账号）"
        } catch {
            message = s4Error(error, fallback: "恢复备份失败").message
        }
    }
}

// MARK: - 5. 关于

@MainActor
private struct AboutSettingsView: View {
    @Environment(\.xmPalette) private var palette

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(palette.accent.gradient)
                    Text("XMPro iOS")
                        .font(.title2.weight(.bold))
                    Text("原生 SwiftUI · iOS 27 Liquid Glass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
            }

            Section("来源与开源许可") {
                Text("本项目移植自开源项目 angusdevgo/XMPro，遵循 AGPL-3.0-or-later 许可证，保留上游版权与许可声明，仅供个人学习与自用。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .xmPageBackground()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}
