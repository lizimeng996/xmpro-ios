// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@MainActor
struct AlbumDetailView: View {
    let albumId: String
    let initialAlbum: Album?
    var onOpenPlayer: (() -> Void)? = nil

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var ascending = true
    @State private var albumPage: AlbumPage?
    @State private var loadedTracks: [Track] = []
    @State private var rangeStart = 1
    @State private var rangeEnd: Int? = 100
    @State private var showingRangeSheet = false
    @State private var customStartText = ""
    @State private var customEndText = ""
    @State private var introExpanded = false
    @State private var loading = true
    @State private var error: XmlyError?
    @State private var notice: String?

    private var subscribed: Bool {
        dependencies.isAlbumSubscribed(albumId)
    }

    private let segmentSize = 100

    init(albumId: String, initialAlbum: Album? = nil, onOpenPlayer: (() -> Void)? = nil) {
        self.albumId = albumId
        self.initialAlbum = initialAlbum
        self.onOpenPlayer = onOpenPlayer
    }

    private var totalCount: Int {
        max(albumPage?.total ?? 0, initialAlbum?.total ?? 0, loadedTracks.count)
    }

    private var segmentRanges: [(start: Int, end: Int)] {
        guard totalCount > 0 else { return [] }
        var ranges: [(Int, Int)] = []
        var s = 1
        while s <= totalCount {
            let e = min(s + segmentSize - 1, totalCount)
            ranges.append((s, e))
            s += segmentSize
        }
        return ranges
    }

    private var rangeButtonLabel: String {
        if let rangeEnd, rangeEnd < totalCount || rangeStart > 1 {
            return "\(rangeStart)-\(min(rangeEnd, totalCount))"
        }
        return "选集"
    }

    var body: some View {
        LoadStateView(state: loadState) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heroHeader
                            .id("album-top")

                        episodesSection
                            .padding(.horizontal, XMMetrics.pagePadding)

                        Color.clear
                            .frame(height: 1)
                            .id("album-bottom")
                    }
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .xmSoftScrollEdge()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            withAnimation {
                                if let first = loadedTracks.first {
                                    proxy.scrollTo(first.id, anchor: .top)
                                } else {
                                    proxy.scrollTo("album-top", anchor: .top)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .accessibilityLabel("滚到顶部")

                        if let currentId = dependencies.playbackSession.track?.id,
                           loadedTracks.contains(where: { $0.id == currentId }) {
                            Button {
                                withAnimation {
                                    proxy.scrollTo(currentId, anchor: .center)
                                }
                            } label: {
                                Image(systemName: "scope")
                            }
                            .accessibilityLabel("定位当前播放")
                        }

                        Button {
                            withAnimation {
                                if let last = loadedTracks.last {
                                    proxy.scrollTo(last.id, anchor: .bottom)
                                } else {
                                    proxy.scrollTo("album-bottom", anchor: .bottom)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .accessibilityLabel("滚到底部")
                    }
                }
            }
        }
        .xmPageBackground()
        .xmToast($notice)
        .navigationTitle(albumPage?.album.title ?? initialAlbum?.title ?? "专辑")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRangeSheet) {
            rangePickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: albumId) {
            async let loadTask: Void = loadRange(start: 1, end: segmentSize)
            async let syncTask: Void = dependencies.syncSubscriptionsIfNeeded()
            _ = await (loadTask, syncTask)
        }
    }

    private var effectiveCoverUrl: String? {
        [
            albumPage?.album.coverUrl,
            initialAlbum?.coverUrl,
            loadedTracks.first(where: { !($0.coverUrl ?? "").isEmpty })?.coverUrl
        ]
        .compactMap { $0 }
        .first { !$0.isEmpty }
    }

    private var effectiveTitle: String {
        if let t = albumPage?.album.title, !t.isEmpty { return t }
        if let t = initialAlbum?.title, !t.isEmpty { return t }
        return "专辑 \(albumId)"
    }

    private var effectiveArtist: String {
        if let a = albumPage?.album.artist, !a.isEmpty { return a }
        if let a = initialAlbum?.artist, !a.isEmpty { return a }
        return "未知主播"
    }

    private var effectiveIntro: String {
        if let i = albumPage?.album.intro, !i.isEmpty { return i }
        if let i = initialAlbum?.intro, !i.isEmpty { return i }
        return ""
    }

    // MARK: 沉浸式头部

    @ViewBuilder
    private var heroHeader: some View {
        if albumPage?.album ?? initialAlbum != nil {
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    XMArtwork(url: effectiveCoverUrl, cornerRadius: 18, symbol: "square.stack")
                        .frame(width: 176, height: 176)
                        .shadow(color: .black.opacity(0.38), radius: 22, y: 12)

                    VStack(spacing: 5) {
                        Text(effectiveTitle)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        Text("\(effectiveArtist) · 共 \(totalCount) 集")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                let targetIndex = loadedTracks.firstIndex(where: {
                                    $0.id == dependencies.playbackSession.track?.id
                                }) ?? 0
                                await playTrack(at: targetIndex)
                            }
                        } label: {
                            Label(
                                dependencies.playbackSession.track?.albumKey == albumId ? "继续播放" : "开始播放",
                                systemImage: "play.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: 118, minHeight: 34)
                        }
                        .xmProminentButton()
                        .disabled(loadedTracks.isEmpty)

                        Button {
                            Task { await toggleSubscribe() }
                        } label: {
                            Label(subscribed ? "已订阅" : "订阅", systemImage: subscribed ? "checkmark" : "plus")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(minWidth: 96, minHeight: 34)
                        }
                        .xmGlassButton()
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, XMMetrics.pagePadding)
                .padding(.top, 20)
                .padding(.bottom, 24)
                .background {
                    XMArtworkBackdrop(url: effectiveCoverUrl, dimming: 0.35)
                        .ignoresSafeArea(edges: .top)
                }

                if !effectiveIntro.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(effectiveIntro)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(introExpanded ? nil : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(introExpanded ? "收起简介" : "展开全部") {
                            withAnimation(.snappy(duration: 0.25)) {
                                introExpanded.toggle()
                            }
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.accent)
                    }
                    .padding(.horizontal, XMMetrics.pagePadding)
                    .padding(.top, 16)
                }
            }
        }
    }

    // MARK: 剧集列表

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            XMSectionHeader(
                title: "剧集",
                badge: "\(totalCount) 集",
                trailing: AnyView(
                    HStack(spacing: 8) {
                        Button {
                            ascending.toggle()
                            Task { await loadRange(start: rangeStart, end: rangeEnd) }
                        } label: {
                            Label(ascending ? "正序" : "倒序", systemImage: ascending ? "arrow.up" : "arrow.down")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(palette.fill, in: Capsule())
                        }
                        .buttonStyle(.xmPressable)

                        Button {
                            customStartText = ""
                            customEndText = ""
                            showingRangeSheet = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption2)
                                Text(rangeButtonLabel)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(palette.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.xmPressable)
                    }
                )
            )

            if loading && loadedTracks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在加载剧集…")
                    Spacer()
                }
                .padding(.vertical, 36)
            } else if loadedTracks.isEmpty {
                XMEmptyState(systemImage: "music.note.list", title: "暂无剧集")
                    .padding(.vertical, 24)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(loadedTracks.enumerated()), id: \.element.id) { index, track in
                        episodeRow(index: index, track: track)
                            .id(track.id)
                        if index < loadedTracks.count - 1 {
                            Divider()
                                .padding(.leading, 52)
                                .opacity(0.6)
                        }
                    }
                }
                .padding(.vertical, 4)
                .xmCard(cornerRadius: XMMetrics.cardRadius)
            }
        }
    }

    private func episodeRow(index: Int, track: Track) -> some View {
        let isCurrent = dependencies.playbackSession.track?.id == track.id
        let isPlaying = isCurrent && dependencies.playbackSession.isPlaying
        let displayNum = track.episode ?? (rangeStart + index)

        return Button {
            Task { await playTrack(at: index) }
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        XMNowPlayingIndicator(isPlaying: isPlaying)
                    } else {
                        Text("\(displayNum)")
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 30, alignment: .center)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title.isEmpty ? "未命名声音" : track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? palette.accent : Color.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        if track.duration > 0 {
                            Text(XMDesign.clock(Int(track.duration.rounded())))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if track.isPaid == true {
                            XMTag(text: track.isAuthorized == true ? "已购" : "付费")
                        }
                    }
                }

                Spacer(minLength: 6)

                if !isCurrent {
                    Image(systemName: "play.circle")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 选集区间 Sheet

    private var rangePickerSheet: some View {
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("共 \(totalCount) 集，选择区间快速跳转")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(segmentRanges, id: \.start) { seg in
                            let selected = rangeStart == seg.start && rangeEnd == seg.end
                            Button {
                                showingRangeSheet = false
                                Task { await loadRange(start: seg.start, end: seg.end) }
                            } label: {
                                Text("\(seg.start)-\(seg.end)")
                                    .font(.subheadline.monospacedDigit().weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(
                                        selected ? palette.accent : palette.fill,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                            }
                            .buttonStyle(.xmPressable)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("自定义区间")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            TextField("起始集", text: $customStartText)
                                .keyboardType(.numberPad)
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Text("至")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            TextField("结束集", text: $customEndText)
                                .keyboardType(.numberPad)
                                .padding(.horizontal, 14)
                                .frame(height: 44)
                                .background(palette.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    HStack {
                        Button("显示全部") {
                            showingRangeSheet = false
                            Task { await loadRange(start: 1, end: nil) }
                        }
                        .xmGlassButton()

                        Spacer()

                        let sVal = Int(customStartText.trimmingCharacters(in: .whitespaces))
                        let eVal = Int(customEndText.trimmingCharacters(in: .whitespaces))
                        let canApply = (sVal != nil || eVal != nil)

                        Button("查看") {
                            let start = max(1, min(sVal ?? 1, max(1, totalCount)))
                            let end = max(start, min(eVal ?? totalCount, max(start, totalCount)))
                            showingRangeSheet = false
                            Task { await loadRange(start: start, end: end) }
                        }
                        .xmProminentButton()
                        .disabled(!canApply)
                    }
                }
                .padding(XMMetrics.pagePadding)
            }
            .navigationTitle("选集区间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showingRangeSheet = false }
                }
            }
        }
    }

    // MARK: 数据加载

    private var loadState: LoadState {
        if loading && albumPage == nil { return .loading }
        if let error, albumPage == nil {
            return .error(error, retry: { Task { await loadRange(start: rangeStart, end: rangeEnd) } })
        }
        return .idle
    }

    /// 精确按 [start, end] 区间加载剧集（end == nil 表示加载全部集数，上限 5000 集）。
    private func loadRange(start: Int, end: Int?) async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }

        do {
            let client = try await dependencies.makeCurrentClient()
            let apiPageSize = ProtocolConfig.XMLY_ALBUM_PAGE_SIZE // 200
            let safeStart = max(1, start)
            let firstPageIdx = ((safeStart - 1) / apiPageSize) + 1

            let firstFetched = try await client.album(
                albumId: albumId,
                page: firstPageIdx,
                pageSize: apiPageSize,
                ascending: ascending
            )
            albumPage = firstFetched

            let total = max(firstFetched.total, firstFetched.tracks.count)
            let actualEnd = min(end ?? total, max(safeStart, total))
            let lastPageIdx = min(((actualEnd - 1) / apiPageSize) + 1, firstPageIdx + 24)

            var combined: [(globalIndex: Int, track: Track)] = []
            var seen: Set<String> = []

            func appendPage(_ fetched: AlbumPage, pageIdx: Int) {
                let base = (pageIdx - 1) * apiPageSize + 1
                for (offset, track) in fetched.tracks.enumerated() {
                    let gIdx = base + offset
                    guard gIdx >= safeStart && gIdx <= actualEnd else { continue }
                    if seen.insert(track.id).inserted {
                        combined.append((gIdx, track))
                    }
                }
            }

            appendPage(firstFetched, pageIdx: firstPageIdx)

            if lastPageIdx > firstPageIdx {
                for p in (firstPageIdx + 1)...lastPageIdx {
                    let nextFetched = try await client.album(
                        albumId: albumId,
                        page: p,
                        pageSize: apiPageSize,
                        ascending: ascending
                    )
                    if nextFetched.tracks.isEmpty { break }
                    appendPage(nextFetched, pageIdx: p)
                }
            }

            rangeStart = safeStart
            rangeEnd = end == nil ? nil : actualEnd
            loadedTracks = combined.map(\.track)
        } catch {
            self.error = s4Error(error, fallback: "加载专辑失败，请重试")
        }
    }

    private func playTrack(at index: Int) async {
        guard loadedTracks.indices.contains(index) else { return }
        await dependencies.playbackSession.playQueue(
            loadedTracks,
            index: index,
            resumePositionMs: nil
        )
        onOpenPlayer?()
    }

    private func toggleSubscribe() async {
        let target = !subscribed
        do {
            try await dependencies.experienceService.setSubscribed(
                albumId: albumId,
                subscribed: target
            )
            dependencies.setAlbumSubscribed(albumId, subscribed: target)
            notice = target ? "已订阅该专辑" : "已取消订阅"
        } catch {
            notice = s4Error(error, fallback: "操作失败，请先登录").message
        }
    }
}
