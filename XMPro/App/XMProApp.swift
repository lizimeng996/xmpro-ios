import SwiftUI

enum XMRootTab: Int, Hashable, CaseIterable, Identifiable {
    case home = 0
    case listen = 1
    case profile = 2
    case search = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "发现"
        case .listen: return "书架"
        case .profile: return "我的"
        case .search: return "搜索"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "sparkles.rectangle.stack"
        case .listen: return "books.vertical"
        case .profile: return "person.crop.circle"
        case .search: return "magnifyingglass"
        }
    }
}

@main
struct XMProApp: App {
    @StateObject private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            XMProRootView(
                dependencies: dependencies,
                themeStore: dependencies.themeStore,
                playbackSession: dependencies.playbackSession
            )
            .environmentObject(dependencies)
        }
    }
}

@MainActor
private struct XMProRootView: View {
    @ObservedObject var dependencies: AppDependencies
    @ObservedObject var themeStore: ThemeStore
    @ObservedObject var playbackSession: PlaybackSession

    @State private var selectedTab: XMRootTab = .home
    @State private var playerPresented = false

    private func openPlayer() { playerPresented = true }

    var body: some View {
        Group {
            if #available(iOS 26.1, *) {
                modernLiquidGlassTabView
            } else {
                legacyTabView
            }
        }
        .xmThemed(themeStore)
        .preferredColorScheme(themeStore.theme.preferredColorScheme)
        .fullScreenCover(isPresented: $playerPresented) {
            PlayerView(onDismiss: { playerPresented = false })
                .environmentObject(dependencies)
                .xmThemed(themeStore)
                .preferredColorScheme(.dark)
        }
        .task {
            await themeStore.load()
            playbackSession.setSoundEffect(themeStore.soundEffect)
            await dependencies.playbackSession.prepare()
        }
        .onChange(of: themeStore.soundEffect) { _, preset in
            playbackSession.setSoundEffect(preset)
        }
    }

    /// iOS 26.1 / 27：原生 Liquid Glass TabView + 独立搜索 Tab + 滚动收缩 + BottomAccessory 迷你播放器
    @available(iOS 26.1, *)
    private var modernLiquidGlassTabView: some View {
        TabView(selection: $selectedTab) {
            Tab(XMRootTab.home.title, systemImage: XMRootTab.home.systemImage, value: XMRootTab.home) {
                LibraryView(onOpenPlayer: openPlayer)
            }

            Tab(XMRootTab.listen.title, systemImage: XMRootTab.listen.systemImage, value: XMRootTab.listen) {
                NavigationStack {
                    ShelfView(onOpenPlayer: openPlayer)
                }
            }

            Tab(XMRootTab.profile.title, systemImage: XMRootTab.profile.systemImage, value: XMRootTab.profile) {
                NavigationStack {
                    SettingsView(onOpenPlayer: openPlayer)
                }
            }

            Tab(XMRootTab.search.title, systemImage: XMRootTab.search.systemImage, value: XMRootTab.search, role: .search) {
                NavigationStack {
                    SearchView(onOpenPlayer: openPlayer)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playbackSession.track != nil) {
            if let track = playbackSession.track {
                NativeGlassMiniPlayer(
                    track: track,
                    session: playbackSession,
                    onTap: openPlayer
                )
            }
        }
    }

    /// iOS 17 – 26.0：系统 TabView + 悬浮玻璃迷你播放器
    private var legacyTabView: some View {
        TabView(selection: $selectedTab) {
            LibraryView(onOpenPlayer: openPlayer)
                .tabItem { Label(XMRootTab.home.title, systemImage: XMRootTab.home.systemImage) }
                .tag(XMRootTab.home)

            NavigationStack { ShelfView(onOpenPlayer: openPlayer) }
                .tabItem { Label(XMRootTab.listen.title, systemImage: XMRootTab.listen.systemImage) }
                .tag(XMRootTab.listen)

            NavigationStack { SearchView(onOpenPlayer: openPlayer) }
                .tabItem { Label(XMRootTab.search.title, systemImage: XMRootTab.search.systemImage) }
                .tag(XMRootTab.search)

            NavigationStack { SettingsView(onOpenPlayer: openPlayer) }
                .tabItem { Label(XMRootTab.profile.title, systemImage: XMRootTab.profile.systemImage) }
                .tag(XMRootTab.profile)
        }
        .overlay(alignment: .bottom) {
            if let track = playbackSession.track {
                LegacyMiniPlayerBar(track: track, session: playbackSession, onTap: openPlayer)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: playbackSession.track?.id)
    }
}

// MARK: - 迷你播放器

/// 迷你播放器共用：播放进度环形按钮
@MainActor
private struct MiniPlayToggle: View {
    @ObservedObject var session: PlaybackSession
    var size: CGFloat = 32

    @Environment(\.xmPalette) private var palette

    private var progress: Double {
        guard session.durationMs > 0 else { return 0 }
        return min(1, Double(session.positionMs) / Double(session.durationMs))
    }

    var body: some View {
        let playing = session.isPlaying || session.state == .loading
        Button {
            session.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "暂停" : "播放")
    }
}

/// 原生 iOS 26 / 27 `.tabViewBottomAccessory` 迷你播放条（自动响应 inline / expanded 形态）
@available(iOS 26.0, *)
@MainActor
private struct NativeGlassMiniPlayer: View {
    let track: Track
    @ObservedObject var session: PlaybackSession
    let onTap: () -> Void

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let compact = placement == .inline

        HStack(spacing: compact ? 8 : 12) {
            Button(action: onTap) {
                HStack(spacing: compact ? 8 : 10) {
                    XMArtwork(url: track.coverUrl, cornerRadius: compact ? 6 : 8)
                        .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title.isEmpty ? "正在播放" : track.title)
                            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !compact {
                            Text(track.album.isEmpty ? track.artist : track.album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开播放器：\(track.title)")

            MiniPlayToggle(session: session, size: compact ? 28 : 32)

            if !compact {
                Button {
                    Task { await session.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一集")
            }
        }
        .padding(.horizontal, compact ? 10 : 14)
    }
}

@MainActor
private struct LegacyMiniPlayerBar: View {
    let track: Track
    @ObservedObject var session: PlaybackSession
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    XMArtwork(url: track.coverUrl, cornerRadius: 8)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title.isEmpty ? "正在播放" : track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(track.album.isEmpty ? track.artist : track.album)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            MiniPlayToggle(session: session, size: 34)

            Button {
                Task { await session.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .xmLiquidGlassRect(cornerRadius: 18)
    }
}
