import AVKit
import SwiftUI

/// 全屏沉浸式播放器：封面模糊取色氛围背景 + 弹性呼吸封面 + iOS 26/27 Liquid Glass 控制层
@MainActor
struct PlayerView: View {
    var onDismiss: (() -> Void)? = nil

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlaybackContentView(
            dependencies: dependencies,
            session: dependencies.playbackSession,
            commentsSession: dependencies.commentsSession,
            experienceService: dependencies.experienceService,
            themeStore: dependencies.themeStore,
            bookmarkService: dependencies.bookmarkService,
            onOpenUser: { dependencies.openUser(track: $0) },
            onClose: {
                if let onDismiss {
                    onDismiss()
                } else {
                    dismiss()
                }
            }
        )
        .sheet(isPresented: Binding(
            get: { dependencies.userPageUID != nil },
            set: { if !$0 { dependencies.userPageUID = nil } }
        )) {
            if let uid = dependencies.userPageUID {
                NavigationStack {
                    UserPageView(uid: uid, service: dependencies.experienceService)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { dependencies.userPageUID = nil }
                            }
                        }
                }
            }
        }
        .alert("提示", isPresented: Binding(
            get: { dependencies.userPageError != nil },
            set: { if !$0 { dependencies.userPageError = nil } }
        )) {
            Button("知道了", role: .cancel) { dependencies.userPageError = nil }
        } message: {
            Text(dependencies.userPageError?.message ?? "")
        }
    }
}

@MainActor
private struct PlaybackContentView: View {
    @ObservedObject var dependencies: AppDependencies
    @ObservedObject var session: PlaybackSession
    @ObservedObject var commentsSession: CommentsSession
    let experienceService: XmlyExperienceService
    @ObservedObject var themeStore: ThemeStore
    let bookmarkService: XmlyBookmarkService?
    let onOpenUser: (Track) -> Void
    let onClose: () -> Void

    @Environment(\.xmPalette) private var palette

    @State private var dragging = false
    @State private var draftPosition = 0.0
    @State private var dragTrackID: String?
    @State private var commentsOpen = false
    @State private var queueOpen = false
    @State private var speedSheetOpen = false
    @State private var timerSheetOpen = false
    @State private var qualitySheetOpen = false
    @State private var bookmarkSaving = false
    @State private var favoriteSaving = false
    @State private var showCaptions = false
    @State private var captions: TrackCaptions = .empty
    @State private var captionsLoading = false
    @State private var commentCount: Int?
    @State private var notice: String?

    private var displayedCommentCount: Int? {
        if commentsSession.total > 0 { return commentsSession.total }
        return commentCount
    }

    private var commentBadgeText: String? {
        guard let count = displayedCommentCount, count > 0 else { return nil }
        if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000.0) }
        if count > 999 { return "999+" }
        return "\(count)"
    }

    private var isFavorited: Bool {
        guard let id = session.track?.id else { return false }
        return dependencies.isTrackFavorited(id)
    }

    private var isBookmarked: Bool {
        guard let id = session.track?.id else { return false }
        return dependencies.isTrackBookmarked(id)
    }

    private var sleepRemainingMs: Int64? {
        guard let target = session.sleepAtMillis else { return nil }
        let remaining = target - Int64(Date().timeIntervalSince1970 * 1_000)
        return remaining > 0 ? remaining : nil
    }

    var body: some View {
        ZStack {
            XMArtworkBackdrop(url: session.track?.coverUrl, dimming: 0.44)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 38, height: 5)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                topBar

                if let track = session.track {
                    VStack(spacing: 0) {
                        Spacer(minLength: 8)

                        if showCaptions {
                            captionsPanel(track)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        } else {
                            artworkStage(track)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }

                        Spacer(minLength: 14)

                        VStack(spacing: 18) {
                            titleRow(track)
                            progressBlock
                            transportRow
                            volumeBlock

                            if session.state == .failed {
                                Button("重试播放") {
                                    Task {
                                        await session.playQueue(
                                            session.queue.queue,
                                            index: session.queue.index,
                                            resumePositionMs: session.positionMs
                                        )
                                    }
                                }
                                .xmProminentButton()
                            }

                            bottomUtilityDock(track)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                } else {
                    Spacer()
                    XMEmptyState(systemImage: "waveform", title: "暂无正在播放的内容")
                    Spacer()
                }
            }
        }
        .xmToast($notice)
        .onChange(of: session.message) { _, newValue in
            if let newValue, !newValue.isEmpty {
                notice = newValue
                session.clearMessage()
            }
        }
        .task {
            await session.prepare()
            await dependencies.syncBookmarks()
        }
        .task(id: session.track?.id ?? "") {
            dragging = false
            dragTrackID = nil
            commentCount = nil
            notice = nil
            await dependencies.syncBookmarks()
            await loadTrackDetails(for: session.track)
        }
        .sheet(isPresented: $commentsOpen, onDismiss: {
            commentsSession.reset()
        }) {
            CommentsSheet(session: commentsSession)
        }
        .sheet(isPresented: $queueOpen) {
            queueSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $speedSheetOpen) {
            speedPickerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $timerSheetOpen) {
            timerPickerSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $qualitySheetOpen) {
            qualityQuickSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .xmLiquidGlassCircle(interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")

            Spacer()

            VStack(spacing: 1) {
                Text("正在收听")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                if let album = session.track?.album, !album.isEmpty {
                    Text(album)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
            }

            Spacer()

            XMGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    XMAudioRoutePicker(activeTint: UIColor(palette.accent))
                        .frame(width: 38, height: 38)
                        .xmLiquidGlassCircle(interactive: true)
                        .accessibilityLabel("切换音频输出设备")

                    Button {
                        queueOpen = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .xmLiquidGlassCircle(interactive: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.queue.queue.isEmpty)
                    .accessibilityLabel("待播列表")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: 封面与字幕舞台

    private func artworkStage(_ track: Track) -> some View {
        let active = session.isPlaying || session.state == .loading
        return VStack(spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showCaptions = true
                }
            } label: {
                XMArtwork(url: track.coverUrl, cornerRadius: 24)
                    .frame(maxWidth: 288, maxHeight: 288)
                    .aspectRatio(1, contentMode: .fit)
                    .scaleEffect(active ? 1.0 : 0.90)
                    .shadow(color: .black.opacity(active ? 0.48 : 0.28), radius: active ? 30 : 16, y: active ? 18 : 8)
                    .animation(.spring(response: 0.48, dampingFraction: 0.72), value: active)
                    .overlay(alignment: .bottomTrailing) {
                        if session.state == .loading {
                            ProgressView()
                                .tint(.white)
                                .padding(10)
                                .xmLiquidGlassCircle(interactive: false)
                                .padding(12)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("点击查看字幕与文稿")

            // 单行实时字幕预览胶囊
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    showCaptions = true
                }
            } label: {
                let previewText: String = {
                    if let activeIdx = captions.activeLineIndex(at: session.positionMs),
                       captions.lines.indices.contains(activeIdx) {
                        return captions.lines[activeIdx].text
                    }
                    if let first = captions.lines.first { return first.text }
                    return captionsLoading ? "正在加载字幕与文稿…" : "查看字幕 / 章节文稿"
                }()
                HStack(spacing: 6) {
                    Image(systemName: "captions.bubble")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(previewText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.xmPressable)
        }
    }

    private func captionsPanel(_ track: Track) -> some View {
        let activeIdx = captions.activeLineIndex(at: session.positionMs)

        return VStack(spacing: 10) {
            HStack {
                Label(
                    captions.sourceLabel.isEmpty ? "字幕与文稿" : captions.sourceLabel,
                    systemImage: "captions.bubble.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Button("返回封面") {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        showCaptions = false
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.white.opacity(0.16), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            if captionsLoading {
                Spacer()
                ProgressView("正在加载字幕…")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            } else if captions.lines.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text("当前声音暂无官方字幕或章节文稿")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("如需实时字幕，可在 iPhone「设置 → 辅助功能 → 实时字幕」开启系统级离线转写。")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button("重新获取") {
                        Task { await loadTrackDetails(for: track) }
                    }
                    .xmGlassButton()
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(captions.lines) { line in
                                let isCurrent = activeIdx == line.id
                                Button {
                                    if let ms = line.timeMs { session.seekTo(ms) }
                                } label: {
                                    Text(line.text)
                                        .font(isCurrent ? .title3.weight(.bold) : .body)
                                        .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(captions.isTimed ? 0.50 : 0.85))
                                        .frame(maxWidth: .infinity, alignment: captions.isTimed ? .center : .leading)
                                        .multilineTextAlignment(captions.isTimed ? .center : .leading)
                                        .lineSpacing(5)
                                }
                                .buttonStyle(.plain)
                                .id(line.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: activeIdx) { _, newValue in
                        if let newValue {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 318)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        )
    }

    // MARK: 标题行

    private func titleRow(_ track: Track) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title.isEmpty ? "未命名声音" : track.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Button {
                    onOpenUser(track)
                } label: {
                    let artist = dependencies.displayNameForArtist(track.artist, track: track)
                    let parts = [artist, track.album].filter { !$0.isEmpty }
                    HStack(spacing: 4) {
                        Text(parts.isEmpty ? "喜马拉雅声音" : parts.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            XMGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        favoriteTrack(track)
                    } label: {
                        Image(systemName: isFavorited ? "heart.fill" : "heart")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isFavorited ? palette.accent : .white)
                            .frame(width: 40, height: 40)
                            .xmLiquidGlassCircle(
                                tint: isFavorited ? palette.accent.opacity(0.25) : nil,
                                interactive: true
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(favoriteSaving)
                    .accessibilityLabel(isFavorited ? "取消收藏" : "收藏声音")

                    Button {
                        toggleBookmark(track)
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isBookmarked ? palette.accent : .white)
                            .frame(width: 40, height: 40)
                            .xmLiquidGlassCircle(
                                tint: isBookmarked ? palette.accent.opacity(0.25) : nil,
                                interactive: true
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(bookmarkSaving || bookmarkService == nil)
                    .accessibilityLabel(isBookmarked ? "移除书签" : "保存书签")
                    .contextMenu {
                        if isBookmarked {
                            Button {
                                saveBookmark(track)
                            } label: {
                                Label("更新书签至当前进度", systemImage: "bookmark.circle")
                            }
                            Button(role: .destructive) {
                                removeBookmark(track)
                            } label: {
                                Label("移除书签", systemImage: "bookmark.slash")
                            }
                        } else {
                            Button {
                                saveBookmark(track)
                            } label: {
                                Label("保存书签", systemImage: "bookmark")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 进度条

    private var progressBlock: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { dragging ? draftPosition : Double(session.positionMs) },
                    set: { draftPosition = $0 }
                ),
                in: 0...max(1, Double(session.durationMs)),
                onEditingChanged: { editing in
                    if editing {
                        dragTrackID = session.track?.id
                        draftPosition = Double(session.positionMs)
                        dragging = true
                    } else {
                        dragging = false
                        if dragTrackID != nil, dragTrackID == session.track?.id {
                            session.seekTo(Int64(draftPosition))
                        }
                        dragTrackID = nil
                    }
                }
            )
            .tint(.white)
            .disabled(session.durationMs <= 0 || session.state == .failed)

            HStack {
                Text(time(dragging ? Int64(draftPosition) : session.positionMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))

                Spacer()

                Button {
                    qualitySheetOpen = true
                } label: {
                    let codec = XMDesign.qualityCodecText(session.actualQuality ?? session.settings.quality)
                    let fx = themeStore.soundEffect == .off ? "原声" : themeStore.soundEffect.displayName
                    Text("\(codec) · \(fx)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.xmPressable)

                Spacer()

                Text(time(session.durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }
        }
    }

    // MARK: 播放主控制

    private var transportRow: some View {
        let playing = session.isPlaying || session.state == .loading
        return HStack(spacing: 0) {
            Button {
                session.skipBy(-10_000)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.xmPressable)
            .accessibilityLabel("后退 10 秒")

            Spacer()

            Button {
                Task { await session.previous() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.xmPressable)
            .accessibilityLabel("上一集")

            Spacer()

            Button {
                session.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 72, height: 72)
                    .xmLiquidGlassCircle(tint: palette.accent.opacity(0.55), interactive: true)
            }
            .buttonStyle(.xmPressable)
            .disabled(session.state == .failed)
            .accessibilityLabel(playing ? "暂停" : "播放")

            Spacer()

            Button {
                Task { await session.next() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.xmPressable)
            .accessibilityLabel("下一集")

            Spacer()

            Button {
                session.skipBy(30_000)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.xmPressable)
            .accessibilityLabel("前进 30 秒")
        }
    }

    // MARK: 音量

    private var volumeBlock: some View {
        HStack(spacing: 10) {
            Image(systemName: session.settings.volume <= 0.01 ? "speaker.slash.fill" : "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))

            Slider(
                value: Binding(
                    get: { session.settings.volume },
                    set: { session.setVolume($0) }
                ),
                in: 0...1
            )
            .tint(.white.opacity(0.8))

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: 底部玻璃工具栏

    private func bottomUtilityDock(_ track: Track) -> some View {
        XMGlassGroup(spacing: 6) {
            HStack(spacing: 0) {
                dockButton(
                    text: String(format: "%.1f×", session.settings.speed),
                    label: "倍速",
                    highlighted: abs(session.settings.speed - 1.0) > 0.05
                ) {
                    speedSheetOpen = true
                }

                Spacer(minLength: 0)

                dockIconButton(
                    icon: showCaptions ? "captions.bubble.fill" : "captions.bubble",
                    label: "字幕",
                    highlighted: showCaptions
                ) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        showCaptions.toggle()
                    }
                }

                Spacer(minLength: 0)

                dockIconButton(
                    icon: "bubble.left",
                    label: "评论",
                    badge: commentBadgeText
                ) {
                    commentsOpen = true
                    Task {
                        await commentsSession.open(trackNumber: track.number)
                        if commentsSession.total > 0 {
                            commentCount = commentsSession.total
                        }
                    }
                }

                Spacer(minLength: 0)

                dockIconButton(
                    icon: "timer",
                    label: sleepRemainingMs.map { "\(max(1, Int($0 / 60_000)))分" } ?? "定时",
                    highlighted: sleepRemainingMs != nil
                ) {
                    timerSheetOpen = true
                }

                Spacer(minLength: 0)

                dockIconButton(
                    icon: "forward.end.alt",
                    label: "跳头尾",
                    highlighted: session.settings.skipTrim
                ) {
                    session.setSkipTrim(
                        enabled: !session.settings.skipTrim,
                        intro: session.settings.introPermille,
                        outro: session.settings.outroPermille,
                        mode: session.settings.skipMode
                    )
                    notice = session.settings.skipTrim ? "已开启跳过头尾" : "已关闭跳过头尾"
                }

                Spacer(minLength: 0)

                dockIconButton(
                    icon: "text.line.first.and.arrowtriangle.forward",
                    label: session.queue.queue.isEmpty ? "队列" : "\(session.queue.queue.count)集",
                    highlighted: false
                ) {
                    queueOpen = true
                }
                .disabled(session.queue.queue.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .xmLiquidGlassCapsule(interactive: true)
        }
    }

    private func dockButton(
        text: String,
        label: String,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(text)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(highlighted ? palette.accent : .white)
                    .frame(height: 20)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(highlighted ? palette.accent : .white.opacity(0.68))
            }
            .frame(minWidth: 44, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.xmPressable)
    }

    private func dockIconButton(
        icon: String,
        label: String,
        highlighted: Bool = false,
        badge: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(highlighted ? palette.accent : .white)
                        .frame(height: 20)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(palette.accent, in: Capsule())
                            .offset(x: 10, y: -5)
                    }
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(highlighted ? palette.accent : .white.opacity(0.68))
                    .lineLimit(1)
            }
            .frame(minWidth: 44, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.xmPressable)
    }

    // MARK: 待播列表 Sheet

    private var queueSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            if let first = session.queue.queue.first {
                                withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                            }
                        } label: {
                            Label("顶部", systemImage: "arrow.up.to.line")
                                .font(.caption.weight(.medium))
                        }
                        .xmGlassButton()

                        Button {
                            if session.queue.queue.indices.contains(session.queue.index) {
                                withAnimation {
                                    proxy.scrollTo(session.queue.queue[session.queue.index].id, anchor: .center)
                                }
                            }
                        } label: {
                            Label("当前集", systemImage: "scope")
                                .font(.caption.weight(.medium))
                        }
                        .xmGlassButton()

                        Button {
                            if let last = session.queue.queue.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        } label: {
                            Label("底部", systemImage: "arrow.down.to.line")
                                .font(.caption.weight(.medium))
                        }
                        .xmGlassButton()

                        Spacer()
                    }
                    .padding(.horizontal, XMMetrics.pagePadding)
                    .padding(.vertical, 10)

                    List {
                        ForEach(Array(session.queue.queue.enumerated()), id: \.element.id) { index, item in
                            let isCurrent = index == session.queue.index
                            Button {
                                queueOpen = false
                                Task {
                                    await session.playQueue(
                                        session.queue.queue,
                                        index: index,
                                        resumePositionMs: nil
                                    )
                                }
                            } label: {
                                XMMediaRow(
                                    coverUrl: item.coverUrl,
                                    title: item.title.isEmpty ? "未命名声音" : item.title,
                                    subtitle: item.duration > 0 ? time(Int64(item.duration * 1_000)) : nil,
                                    highlighted: isCurrent,
                                    coverSize: 44
                                ) {
                                    if isCurrent {
                                        XMNowPlayingIndicator(isPlaying: session.isPlaying)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .listStyle(.plain)
                }
                .navigationTitle("待播列表（\(session.queue.queue.count)）")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { queueOpen = false }
                    }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("清空", role: .destructive) {
                            session.stop()
                            queueOpen = false
                        }
                    }
                }
                .onAppear {
                    if session.queue.queue.indices.contains(session.queue.index) {
                        proxy.scrollTo(session.queue.queue[session.queue.index].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: 倍速 Sheet

    private var speedPickerSheet: some View {
        let presets: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
        return NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%.2f×", session.settings.speed))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(palette.accent)
                    Spacer()
                    if abs(session.settings.speed - 1.0) > 0.02 {
                        Button("恢复 1.0×") {
                            session.setSpeed(1.0)
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }

                Slider(
                    value: Binding(
                        get: { session.settings.speed },
                        set: { session.setSpeed($0) }
                    ),
                    in: 0.5...3.0,
                    step: 0.05
                )
                .tint(palette.accent)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                    ForEach(presets, id: \.self) { value in
                        let active = abs(session.settings.speed - value) < 0.02
                        Button(String(format: "%.2g×", value)) {
                            session.setSpeed(value)
                        }
                        .font(.subheadline.monospacedDigit().weight(active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(active ? palette.accent : palette.fill, in: Capsule())
                        .buttonStyle(.xmPressable)
                    }
                }
                Spacer()
            }
            .padding(XMMetrics.pagePadding)
            .navigationTitle("播放倍速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { speedSheetOpen = false }
                }
            }
        }
    }

    // MARK: 定时关闭 Sheet

    private var timerPickerSheet: some View {
        let options: [(String, Int?)] = [
            ("关闭定时", nil),
            ("15 分钟", 15),
            ("30 分钟", 30),
            ("45 分钟", 45),
            ("60 分钟", 60),
            ("90 分钟", 90)
        ]
        return NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let remaining = sleepRemainingMs {
                    HStack {
                        Image(systemName: "moon.zzz.fill")
                            .foregroundStyle(palette.accent)
                        Text("剩余 \(time(remaining)) 后暂停播放")
                            .font(.subheadline.monospacedDigit().weight(.medium))
                            .foregroundStyle(palette.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(options, id: \.0) { label, mins in
                        Button(label) {
                            session.setSleepTimer(minutes: mins)
                            timerSheetOpen = false
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mins == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(palette.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .buttonStyle(.xmPressable)
                    }
                }
                Spacer()
            }
            .padding(XMMetrics.pagePadding)
            .navigationTitle("定时关闭")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { timerSheetOpen = false }
                }
            }
        }
    }

    // MARK: 音质与音效 Sheet

    private var qualityQuickSheet: some View {
        let qualities: [(String, String)] = [
            ("自动", "auto"), ("高清", "m4a_128"), ("标准", "m4a_64"), ("省流", "mp3_32"), ("流畅", "m4a_24")
        ]
        return NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("音质偏好")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let actual = session.actualQuality {
                            Text("当前流：\(XMDesign.qualityCodecText(actual))")
                                .font(.caption)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    Picker("音质偏好", selection: Binding(
                        get: { session.settings.quality },
                        set: { session.setQuality($0) }
                    )) {
                        ForEach(qualities, id: \.1) { title, code in
                            Text(title).tag(code)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("音效模式")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    XMFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(SoundEffectPreset.allCases) { preset in
                            XMChip(title: preset.displayName, selected: themeStore.soundEffect == preset) {
                                Task { await themeStore.selectSoundEffect(preset) }
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(XMMetrics.pagePadding)
            .navigationTitle("音质与音效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { qualitySheetOpen = false }
                }
            }
        }
    }

    // MARK: 数据与动作

    private func loadTrackDetails(for track: Track?) async {
        guard let track else {
            captions = .empty
            commentCount = nil
            return
        }
        captionsLoading = true
        defer { captionsLoading = false }
        do {
            let client = try await dependencies.makeCurrentClient()
            let summary = try await client.trackDetailSummary(
                number: track.number,
                fallbackIntro: track.intro
            )
            captions = summary.captions
            if let count = summary.commentCount {
                commentCount = count
            } else if let page = try? await client.trackComments(number: track.number, page: 1, pageSize: 1) {
                commentCount = page.total
            }
        } catch {
            captions = XmlyClientService.parseCaptions(
                lyric: "", richIntro: "", intro: track.intro
            )
        }
    }

    private func toggleBookmark(_ track: Track) {
        if isBookmarked {
            removeBookmark(track)
        } else {
            saveBookmark(track)
        }
    }

    private func saveBookmark(_ track: Track) {
        guard let bookmarkService, !bookmarkSaving else { return }
        let position = session.positionMs
        bookmarkSaving = true
        Task {
            do {
                let saved = try await bookmarkService.add(track: track, positionMs: position)
                dependencies.recordBookmarks(saved)
                notice = saved.contains { $0.track.id == track.id }
                    ? "已保存书签" : "登录后可保存书签"
            } catch {
                notice = s4Error(error, fallback: "保存书签失败，请重试").message
            }
            bookmarkSaving = false
        }
    }

    private func removeBookmark(_ track: Track) {
        guard let bookmarkService, !bookmarkSaving else { return }
        bookmarkSaving = true
        Task {
            do {
                let saved = try await bookmarkService.remove(trackId: track.id)
                dependencies.recordBookmarks(saved)
                notice = "已移除书签"
            } catch {
                notice = s4Error(error, fallback: "移除书签失败，请重试").message
            }
            bookmarkSaving = false
        }
    }

    private func favoriteTrack(_ track: Track) {
        guard !favoriteSaving else { return }
        favoriteSaving = true
        let target = !isFavorited
        Task {
            do {
                try await experienceService.setFavorite(track: track, favorite: target)
                dependencies.setTrackFavorited(track.id, favorited: target)
                notice = target ? "已收藏该声音" : "已取消收藏"
            } catch {
                notice = s4Error(error, fallback: "收藏失败，请先登录").message
            }
            favoriteSaving = false
        }
    }

    private func time(_ ms: Int64) -> String {
        XMDesign.clock(Int(ms / 1_000))
    }
}

/// 系统原生音频输出设备选择器（蓝牙音箱 / AirPods / HomePod / AirPlay）
private struct XMAudioRoutePicker: UIViewRepresentable {
    var activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = activeTint
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = activeTint
    }
}
