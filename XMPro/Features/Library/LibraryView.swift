import SwiftUI

/// 「发现」首页：大标题 + 频道胶囊 + 沉浸式推荐轮播 + 排行榜分页网格 + 横滑书架
@MainActor
struct LibraryView: View {
    var onOpenPlayer: (() -> Void)? = nil

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var channels: [ChannelItem] = []
    @State private var selectedChannelId: String = "2"
    @State private var subTabs: [HomeSubTab] = []
    @State private var selectedSubTabId: String?
    @State private var selectedRankingIndex = 0
    @State private var modules: [HomeModuleItem] = []
    @State private var bannerID: String?
    @State private var loadingFeed = true
    @State private var feedError: String?
    @State private var feedRequestToken = 0

    private var bannerCards: [HomeAlbumCard] {
        var seen: Set<String> = []
        var withCover: [HomeAlbumCard] = []
        var fallback: [HomeAlbumCard] = []
        for module in modules {
            let source = module.cards.isEmpty
                ? module.rankings.flatMap(\.cards)
                : module.cards
            for card in source where seen.insert(card.id).inserted {
                if let url = card.album.coverUrl, !url.isEmpty {
                    withCover.append(card)
                    if withCover.count >= 5 { return withCover }
                } else if fallback.count < 5 {
                    fallback.append(card)
                }
            }
        }
        return withCover.isEmpty ? fallback : withCover
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: XMMetrics.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        channelStrip
                        if !subTabs.isEmpty {
                            subTabStrip
                        }
                    }

                    if !bannerCards.isEmpty {
                        bannerCarousel
                    }

                    modulesContent
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .xmSoftScrollEdge()
            .xmPageBackground()
            .refreshable {
                await loadChannelsAndFeed(forceSync: true)
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadChannelsAndFeed(forceSync: true) }
                    } label: {
                        if loadingFeed {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(loadingFeed)
                    .accessibilityLabel("刷新首页")
                }
            }
            .task(id: dependencies.accountRevision) {
                await loadChannelsAndFeed(forceSync: false)
            }
            .task(id: bannerCards.map(\.id)) {
                await autoAdvanceBanner()
            }
        }
    }

    // MARK: 频道

    private var channelStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(channels.filter(\.enabled)) { channel in
                    XMChip(title: channel.title, selected: channel.id == selectedChannelId) {
                        selectChannel(channel.id)
                    }
                }
            }
            .padding(.horizontal, XMMetrics.pagePadding)
        }
        .scrollIndicators(.hidden)
    }

    private var subTabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                ForEach(subTabs) { tab in
                    let selected = tab.id == selectedSubTabId
                    Button {
                        guard selectedSubTabId != tab.id else { return }
                        selectedSubTabId = tab.id
                        selectedRankingIndex = 0
                        Task { await loadFeed(channelId: selectedChannelId, tabId: tab.id) }
                    } label: {
                        VStack(spacing: 5) {
                            Text(tab.title)
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                            Capsule()
                                .fill(selected ? palette.accent : Color.clear)
                                .frame(width: 16, height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, XMMetrics.pagePadding)
            .animation(.snappy(duration: 0.2), value: selectedSubTabId)
        }
        .scrollIndicators(.hidden)
    }

    private func selectChannel(_ id: String) {
        guard selectedChannelId != id else { return }
        selectedChannelId = id
        subTabs = []
        selectedSubTabId = nil
        selectedRankingIndex = 0
        modules = []
        bannerID = nil
        Task { await loadFeed(channelId: id, tabId: nil) }
    }

    // MARK: 推荐轮播

    private var bannerCarousel: some View {
        let cards = bannerCards
        return VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        NavigationLink {
                            AlbumDetailView(albumId: card.album.id, initialAlbum: card.album, onOpenPlayer: onOpenPlayer)
                        } label: {
                            HeroBannerCard(card: card)
                        }
                        .buttonStyle(.xmPressable)
                        .containerRelativeFrame(.horizontal)
                        .id(card.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, XMMetrics.pagePadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $bannerID)
            .scrollIndicators(.hidden)
            .frame(height: 184)
            .id("\(selectedChannelId)-\(selectedSubTabId ?? "")")

            if cards.count > 1 {
                HStack(spacing: 6) {
                    ForEach(cards) { card in
                        let active = (bannerID ?? cards.first?.id) == card.id
                        Capsule()
                            .fill(active ? palette.accent : Color.primary.opacity(0.18))
                            .frame(width: active ? 18 : 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: bannerID)
                .accessibilityHidden(true)
            }
        }
    }

    private func autoAdvanceBanner() async {
        let ids = bannerCards.map(\.id)
        guard ids.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            let current = ids.firstIndex(of: bannerID ?? ids[0]) ?? 0
            withAnimation(.easeInOut(duration: 0.45)) {
                bannerID = ids[(current + 1) % ids.count]
            }
        }
    }

    // MARK: 模块

    @ViewBuilder
    private var modulesContent: some View {
        if let feedError, modules.isEmpty {
            XMEmptyState(systemImage: "wifi.exclamationmark", title: "加载失败", message: feedError) {
                Button("重新加载") {
                    Task { await loadFeed(channelId: selectedChannelId, tabId: selectedSubTabId) }
                }
                .xmProminentButton()
            }
            .padding(.top, 40)
        } else if loadingFeed && modules.isEmpty {
            loadingSkeleton
        } else {
            LazyVStack(alignment: .leading, spacing: XMMetrics.sectionSpacing) {
                ForEach(modules) { module in
                    if !module.rankings.isEmpty {
                        rankingModuleView(module)
                    } else if !module.cards.isEmpty {
                        shelfModuleView(module)
                    }
                }
            }
        }
    }

    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: XMMetrics.sectionSpacing) {
            RoundedRectangle(cornerRadius: XMMetrics.cardRadius, style: .continuous)
                .fill(palette.fill)
                .frame(height: 184)
                .padding(.horizontal, XMMetrics.pagePadding)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    Text("精彩推荐内容").font(.title3.bold())
                    HStack(spacing: 14) {
                        ForEach(0..<3, id: \.self) { _ in
                            XMCoverTile(coverUrl: nil, title: "专辑标题占位文字", subtitle: "主播")
                        }
                    }
                }
                .padding(.horizontal, XMMetrics.pagePadding)
            }
        }
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
        .accessibilityLabel("正在加载内容")
    }

    /// 排行榜：分榜胶囊 + 横向分页 4 行网格（Apple Music 榜单风格）
    @ViewBuilder
    private func rankingModuleView(_ module: HomeModuleItem) -> some View {
        let safeIndex = min(selectedRankingIndex, max(0, module.rankings.count - 1))
        let currentRanking = module.rankings[safeIndex]
        let rows = Array(repeating: GridItem(.fixed(64), spacing: 10), count: min(4, max(1, currentRanking.cards.count)))

        VStack(alignment: .leading, spacing: 14) {
            XMSectionHeader(title: module.title, subtitle: currentRanking.title)
                .padding(.horizontal, XMMetrics.pagePadding)

            if module.rankings.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(module.rankings.enumerated()), id: \.element.id) { idx, item in
                            XMChip(title: item.title, selected: idx == safeIndex) {
                                withAnimation(.snappy) { selectedRankingIndex = idx }
                            }
                        }
                    }
                    .padding(.horizontal, XMMetrics.pagePadding)
                }
                .scrollIndicators(.hidden)
            }

            ScrollView(.horizontal) {
                LazyHGrid(rows: rows, spacing: 16) {
                    ForEach(Array(currentRanking.cards.enumerated()), id: \.element.id) { idx, card in
                        NavigationLink {
                            AlbumDetailView(albumId: card.album.id, initialAlbum: card.album, onOpenPlayer: onOpenPlayer)
                        } label: {
                            rankingRow(card: card, rank: card.rank ?? (idx + 1))
                        }
                        .buttonStyle(.xmPressable)
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.88 }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, XMMetrics.pagePadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .id(currentRanking.id)
        }
    }

    private func rankingRow(card: HomeAlbumCard, rank: Int) -> some View {
        HStack(spacing: 12) {
            XMArtwork(url: card.album.coverUrl, cornerRadius: 10)
                .frame(width: 64, height: 64)

            Text("\(rank)")
                .font(.title3.weight(.heavy).monospacedDigit())
                .foregroundStyle(rank <= 3 ? palette.accent : Color.secondary)
                .frame(minWidth: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(metaLine(for: card, preferPlays: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let score = card.score {
                    XMTag(text: "\(score) 分")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 64)
        .contentShape(Rectangle())
    }

    /// 普通推荐模块：横滑封面书架
    private func shelfModuleView(_ module: HomeModuleItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            XMSectionHeader(title: module.title)
                .padding(.horizontal, XMMetrics.pagePadding)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(module.cards) { card in
                        NavigationLink {
                            AlbumDetailView(albumId: card.album.id, initialAlbum: card.album, onOpenPlayer: onOpenPlayer)
                        } label: {
                            XMCoverTile(
                                coverUrl: card.album.coverUrl,
                                title: card.album.title,
                                subtitle: tileSubtitle(for: card),
                                badge: card.playCount.map(XMDesign.formatCount)
                            )
                        }
                        .buttonStyle(.xmPressable)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, XMMetrics.pagePadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private func tileSubtitle(for card: HomeAlbumCard) -> String {
        if let score = card.score { return "\(score) 分 · \(card.album.artist)" }
        return card.album.artist
    }

    private func metaLine(for card: HomeAlbumCard, preferPlays: Bool) -> String {
        var parts: [String] = []
        if !card.album.artist.isEmpty {
            parts.append(card.album.artist)
        }
        if preferPlays, let plays = card.playCount {
            parts.append("\(XMDesign.formatCount(plays)) 播放")
        } else if let subs = card.subscribeCount {
            parts.append("\(XMDesign.formatCount(subs)) 订阅")
        } else if card.album.total > 0 {
            parts.append("\(card.album.total) 集")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 数据

    private func loadChannelsAndFeed(forceSync: Bool) async {
        var saved = await dependencies.channelService.loadSavedChannels()
        if forceSync || saved.allSatisfy({ Int($0.id) == nil }) {
            if let synced = try? await dependencies.channelService.syncRemoteChannels(), !synced.isEmpty {
                saved = synced
            }
        }
        channels = saved
        let enabled = saved.filter(\.enabled)
        if !enabled.contains(where: { $0.id == selectedChannelId }), let first = enabled.first {
            selectedChannelId = first.id
        }
        await loadFeed(channelId: selectedChannelId, tabId: selectedSubTabId)
    }

    private func loadFeed(channelId: String, tabId: String?) async {
        feedRequestToken += 1
        let token = feedRequestToken
        loadingFeed = true
        feedError = nil
        do {
            let fetched = try await dependencies.channelService.fetchModules(
                channelId: channelId, tabId: tabId
            )
            guard !Task.isCancelled, token == feedRequestToken else { return }
            let discoveredTabs = fetched.flatMap(\.subTabs)
            if tabId == nil && !discoveredTabs.isEmpty && fetched.allSatisfy({ $0.albums.isEmpty }) {
                subTabs = discoveredTabs
                let chosen = discoveredTabs.first(where: \.isDefault) ?? discoveredTabs[0]
                selectedSubTabId = chosen.id
                let tabModules = try await dependencies.channelService.fetchModules(
                    channelId: channelId, tabId: chosen.id
                )
                guard !Task.isCancelled, token == feedRequestToken else { return }
                modules = tabModules
            } else {
                if tabId == nil {
                    subTabs = []
                    selectedSubTabId = nil
                }
                modules = fetched
            }
            bannerID = bannerCards.first?.id
            selectedRankingIndex = 0
            loadingFeed = false
        } catch {
            if error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || Task.isCancelled {
                return
            }
            guard token == feedRequestToken else { return }
            feedError = s4Error(error, fallback: "加载首页推荐失败，请检查网络后重试").message
            loadingFeed = false
        }
    }
}

/// 推荐轮播卡：模糊封面氛围底 + 方形封面 + 文案
private struct HeroBannerCard: View {
    let card: HomeAlbumCard

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: XMMetrics.cardRadius, style: .continuous)
        HStack(spacing: 16) {
            XMArtwork(url: card.album.coverUrl, cornerRadius: 14)
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if let score = card.score {
                        Text("\(score) 分")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                    if let plays = card.playCount {
                        Label(XMDesign.formatCount(plays), systemImage: "play.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Text(card.album.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !card.album.intro.isEmpty {
                    Text(card.album.intro)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if !card.album.artist.isEmpty {
                    Text(card.album.artist)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frame(height: 184)
        .background {
            XMArtworkBackdrop(url: card.album.coverUrl, dimming: 0.25)
        }
        .clipShape(shape)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }
}
