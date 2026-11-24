// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// 「书架」主 Tab：大标题 + 原生筛选 + 分段标签（听更新／订阅／历史／收藏／书签）+ 原生列表
@MainActor
struct ShelfView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case updates = "听更新"
        case subscriptions = "订阅"
        case history = "历史"
        case favorites = "收藏"
        case bookmarks = "书签"

        var id: String { rawValue }
    }

    var onOpenPlayer: (() -> Void)? = nil

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var tab: Tab = .updates
    @State private var filterText = ""
    @State private var updates: [UpdateItem] = []
    @State private var subscriptions: [SubscriptionItem] = []
    @State private var historyRecords: [HistoryRecord] = []
    @State private var favorites: [Track] = []
    @State private var bookmarks: [Bookmark] = []
    @State private var page = 1
    @State private var hasMore = false
    @State private var nextTimeline: Int64?
    @State private var loading = false
    @State private var error: XmlyError?
    @State private var notice: String?
    @State private var loginOpen = false

    private var keyword: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredUpdates: [UpdateItem] {
        guard !keyword.isEmpty else { return updates }
        return updates.filter {
            $0.track.title.lowercased().contains(keyword)
                || $0.track.album.lowercased().contains(keyword)
                || $0.track.artist.lowercased().contains(keyword)
        }
    }

    private var filteredSubscriptions: [SubscriptionItem] {
        guard !keyword.isEmpty else { return subscriptions }
        return subscriptions.filter {
            $0.album.title.lowercased().contains(keyword)
                || $0.album.artist.lowercased().contains(keyword)
                || $0.latestTitle.lowercased().contains(keyword)
        }
    }

    private var filteredHistory: [HistoryRecord] {
        guard !keyword.isEmpty else { return historyRecords }
        return historyRecords.filter {
            $0.track.title.lowercased().contains(keyword)
                || $0.track.album.lowercased().contains(keyword)
        }
    }

    private var filteredFavorites: [Track] {
        guard !keyword.isEmpty else { return favorites }
        return favorites.filter {
            $0.title.lowercased().contains(keyword)
                || $0.album.lowercased().contains(keyword)
                || $0.artist.lowercased().contains(keyword)
        }
    }

    private var filteredBookmarks: [Bookmark] {
        guard !keyword.isEmpty else { return bookmarks }
        return bookmarks.filter {
            $0.track.title.lowercased().contains(keyword)
                || $0.track.album.lowercased().contains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("书架分类", selection: $tab) {
                ForEach(Tab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, XMMetrics.pagePadding)
            .padding(.vertical, 10)

            contentBody
        }
        .xmPageBackground()
        .xmToast($notice)
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $filterText, prompt: "筛选更新、订阅、历史与收藏")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load(reset: true) }
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(loading)
                .accessibilityLabel("刷新书架")
            }
        }
        .task(id: "\(tab.rawValue)-\(dependencies.accountRevision)") {
            await load(reset: true)
        }
        .navigationDestination(isPresented: $loginOpen) {
            LoginView(initialMode: .sms) { successMessage in
                loginOpen = false
                notice = successMessage
                Task { await load(reset: true) }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if loading && currentIsEmpty {
            Spacer()
            ProgressView("正在加载\(tab.rawValue)…")
                .font(.subheadline)
            Spacer()
        } else if let error, currentIsEmpty {
            XMEmptyState(
                systemImage: error.code == XmlyError.Code.loginRequired.rawValue ? "person.crop.circle.badge.exclamationmark" : "wifi.exclamationmark",
                title: "无法加载\(tab.rawValue)",
                message: error.message
            ) {
                HStack(spacing: 12) {
                    Button("重试") { Task { await load(reset: true) } }
                        .xmGlassButton()
                    if error.code == XmlyError.Code.loginRequired.rawValue {
                        Button("去登录") {
                            loginOpen = true
                        }
                        .xmProminentButton()
                    }
                }
            }
        } else if currentIsEmpty {
            XMEmptyState(
                systemImage: emptyIcon,
                title: emptyTitle,
                message: emptyHint
            )
        } else {
            List {
                switch tab {
                case .updates:
                    ForEach(filteredUpdates, id: \.track.id) { item in
                        trackRow(
                            track: item.track,
                            subtitle: item.track.album.isEmpty ? item.track.artist : item.track.album,
                            resumeMs: nil
                        )
                    }

                case .subscriptions:
                    ForEach(filteredSubscriptions, id: \.album.id) { item in
                        subscriptionRow(item)
                    }

                case .history:
                    ForEach(filteredHistory, id: \.track.id) { record in
                        let progress: Double? = record.track.duration > 0
                            ? record.positionSeconds / record.track.duration
                            : nil
                        trackRow(
                            track: record.track,
                            subtitle: "听到 \(XMDesign.clock(Int(record.positionSeconds.rounded()))) · \(record.track.album)",
                            resumeMs: Int64(max(0, record.positionSeconds * 1_000)),
                            progress: progress
                        )
                    }

                case .favorites:
                    ForEach(filteredFavorites, id: \.id) { track in
                        trackRow(
                            track: track,
                            subtitle: track.album.isEmpty ? track.artist : track.album,
                            resumeMs: nil
                        )
                        .swipeActions(edge: .trailing) {
                            Button("取消收藏", role: .destructive) {
                                Task { await unfavorite(track) }
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await unfavorite(track) }
                            } label: {
                                Label("取消收藏", systemImage: "heart.slash")
                            }
                        }
                    }

                case .bookmarks:
                    ForEach(filteredBookmarks, id: \.track.id) { bookmark in
                        trackRow(
                            track: bookmark.track,
                            subtitle: "书签 \(XMDesign.clock(Int(bookmark.positionMs / 1_000))) · \(bookmark.track.album)",
                            resumeMs: bookmark.positionMs
                        )
                        .swipeActions(edge: .trailing) {
                            Button("删除", role: .destructive) {
                                Task { await removeBookmark(bookmark.track.id) }
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await removeBookmark(bookmark.track.id) }
                            } label: {
                                Label("删除书签", systemImage: "trash")
                            }
                        }
                    }
                }

                if hasMore && (tab == .updates || tab == .subscriptions || tab == .favorites) {
                    HStack {
                        Spacer()
                        Button(loading ? "加载中…" : "加载更多") {
                            Task { await load(reset: false) }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(palette.accent)
                        .disabled(loading)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .xmPageBackground()
            .refreshable {
                await load(reset: true)
            }
        }
    }

    private func subscriptionRow(_ item: SubscriptionItem) -> some View {
        NavigationLink {
            AlbumDetailView(
                albumId: item.album.id,
                initialAlbum: item.album,
                onOpenPlayer: onOpenPlayer
            )
        } label: {
            XMMediaRow(
                coverUrl: item.album.coverUrl,
                title: item.album.title,
                subtitle: item.latestTitle.isEmpty ? item.album.artist : item.latestTitle
            ) {
                if item.unreadCount > 0 {
                    XMTag(text: "更新 \(item.unreadCount)", prominent: true)
                }
            }
        }
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing) {
            Button("取消订阅", role: .destructive) {
                Task { await unsubscribe(item.album) }
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await unsubscribe(item.album) }
            } label: {
                Label("取消订阅", systemImage: "bookmark.slash")
            }
        }
    }

    private func trackRow(
        track: Track,
        subtitle: String,
        resumeMs: Int64?,
        progress: Double? = nil
    ) -> some View {
        let isCurrent = dependencies.playbackSession.track?.id == track.id
        let isPlaying = isCurrent && dependencies.playbackSession.isPlaying

        return Button {
            Task {
                await dependencies.playbackSession.play(track: track, resumePositionMs: resumeMs)
                onOpenPlayer?()
            }
        } label: {
            XMMediaRow(
                coverUrl: track.coverUrl,
                title: track.title.isEmpty ? "未命名声音" : track.title,
                subtitle: subtitle,
                highlighted: isCurrent,
                progress: progress
            ) {
                if isCurrent {
                    XMNowPlayingIndicator(isPlaying: isPlaying)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    private var currentIsEmpty: Bool {
        switch tab {
        case .updates: return filteredUpdates.isEmpty
        case .subscriptions: return filteredSubscriptions.isEmpty
        case .history: return filteredHistory.isEmpty
        case .favorites: return filteredFavorites.isEmpty
        case .bookmarks: return filteredBookmarks.isEmpty
        }
    }

    private var emptyIcon: String {
        if !keyword.isEmpty { return "magnifyingglass" }
        switch tab {
        case .updates: return "sparkles"
        case .subscriptions: return "books.vertical"
        case .history: return "clock"
        case .favorites: return "heart"
        case .bookmarks: return "bookmark"
        }
    }

    private var emptyTitle: String {
        if !keyword.isEmpty { return "无匹配结果" }
        switch tab {
        case .updates: return "暂无更新"
        case .subscriptions: return "暂无订阅"
        case .history: return "暂无历史"
        case .favorites: return "暂无收藏"
        case .bookmarks: return "暂无书签"
        }
    }

    private var emptyHint: String? {
        if !keyword.isEmpty { return "未找到包含“\(filterText)”的内容" }
        return nil
    }

    private func load(reset: Bool) async {
        loading = true
        error = nil
        if reset {
            page = 1
            nextTimeline = nil
            hasMore = false
        } else {
            page += 1
        }

        do {
            switch tab {
            case .updates:
                let result = try await dependencies.experienceService.updates(
                    before: reset ? nil : nextTimeline
                )
                if reset { updates = result.items } else { updates.append(contentsOf: result.items) }
                hasMore = result.hasMore
                nextTimeline = result.nextTimeline
            case .subscriptions:
                let result = try await dependencies.experienceService.subscriptions(page: page)
                if reset { subscriptions = result.items } else { subscriptions.append(contentsOf: result.items) }
                dependencies.recordSubscriptions(result.items, replace: reset && !result.hasMore)
                hasMore = result.hasMore
            case .history:
                let service = try await dependencies.makeCurrentHistoryService()
                historyRecords = try await service.records()
                hasMore = false
            case .favorites:
                let result = try await dependencies.experienceService.favorites(page: page)
                if reset { favorites = result.items } else { favorites.append(contentsOf: result.items) }
                dependencies.recordFavorites(result.items)
                hasMore = result.hasMore
            case .bookmarks:
                bookmarks = await dependencies.bookmarkService?.list() ?? []
                dependencies.recordBookmarks(bookmarks)
                hasMore = false
            }
        } catch {
            if error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || Task.isCancelled {
                return
            }
            self.error = s4Error(error, fallback: "加载\(tab.rawValue)失败，请确认已登录")
            if !reset { page = max(1, page - 1) }
        }
        loading = false
    }

    private func unsubscribe(_ album: Album) async {
        do {
            try await dependencies.experienceService.setSubscribed(albumId: album.id, subscribed: false)
            subscriptions.removeAll { $0.album.id == album.id }
            dependencies.setAlbumSubscribed(album.id, subscribed: false)
            notice = "已取消订阅：\(album.title)"
        } catch {
            notice = s4Error(error, fallback: "取消订阅失败").message
        }
    }

    private func unfavorite(_ track: Track) async {
        do {
            try await dependencies.experienceService.setFavorite(track: track, favorite: false)
            favorites.removeAll { $0.id == track.id }
            dependencies.setTrackFavorited(track.id, favorited: false)
            notice = "已取消收藏：\(track.title)"
        } catch {
            notice = s4Error(error, fallback: "取消收藏失败").message
        }
    }

    private func removeBookmark(_ trackId: String) async {
        guard let service = dependencies.bookmarkService else { return }
        do {
            bookmarks = try await service.remove(trackId: trackId)
            dependencies.recordBookmarks(bookmarks)
            notice = "已移除书签"
        } catch {
            notice = s4Error(error, fallback: "删除书签失败").message
        }
    }
}

/// 兼容旧导航引用
@MainActor
struct HistoryView: View {
    var body: some View {
        ShelfView()
    }
}
