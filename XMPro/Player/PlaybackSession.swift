import Combine
import Foundation

@MainActor
final class PlaybackSession: ObservableObject {
    typealias ClientFactory = @MainActor () async throws -> any PlaybackClient
    typealias HistoryFactory = @MainActor (String) async throws -> any PlaybackHistory

    @Published private(set) var track: Track?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var settings = PlaybackSettings()
    @Published private(set) var message: String?
    @Published private(set) var sleepAtMillis: Int64?
    @Published private(set) var pendingSyncCount = 0
    @Published private(set) var actualQuality: String?

    private(set) var sessionIdentity: String?
    let bridge: PlaybackQueueBridge

    private let engine: any PlayerEngine
    private let clientFactory: ClientFactory
    private let historyFactory: HistoryFactory
    private let store: any PlaybackStore
    private let clock: any PlaybackClock
    private let initialLoad: Task<PlaybackStoredState, Error>

    private var controls: PlaybackSystemControls?
    private var didPrepare = false
    private var storageReady = false
    private var editedSettingsKeys: Set<String> = []
    private var localProgress: [LocalPlaybackProgress] = []
    private var pendingSync: [PendingPlaybackSync] = []
    private var persistenceTask: Task<Bool, Never>?
    private var syncTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var bridgeTask: Task<Void, Never>?

    private var playRequest: UInt64 = 0
    private var autoAdvanceRequest: UInt64 = 0
    private var selectionPending = false
    private var queueVersion: UInt64 = 0
    private var activeItemID: UUID?
    private var sessionTrack: Track?
    private var sessionClient: (any PlaybackClient)?
    private var sessionStartedAt: Int64?
    private var albumPage: PlaybackAlbumPage?
    private var lastSyncAt: Int64 = 0
    private var lastLocalSaveAt: Int64 = 0
    private var lastProgressTimestamp: Int64 = 0
    private var lastEndedItem: UUID?
    private var lastAdvanceAt: Int64 = 0
    private var endingItem: UUID?

    // S5 可选扩展钩子：听时账本与智能跳过静音（未注入时不改变 S3 既有行为）。
    var usageLedger: UsageLedger?
    var smartSkipScanner: SmartSkipScanner?
    private var currentRequiresReward = false
    private var activeSilenceIntervals: [SilenceInterval] = []
    private var lastSmartSkipTargetMs: Int64 = -1
    private var streamRecoveryAttempts = 0
    private var streamRecoveryTrackID: String?
    private var streamRecoveryTask: Task<Void, Never>?

    private struct PreparedNext {
        let queue: PlaybackQueue
        let page: PlaybackAlbumPage?
        let audio: ResolvedAudio
    }

    private struct Prefetch {
        let source: UUID
        let identity: String
        let quality: String
        let createdAt: Int64
        let task: Task<PreparedNext?, Error>
    }

    private var prefetch: Prefetch?

    init(
        engine: any PlayerEngine,
        store: any PlaybackStore,
        clock: any PlaybackClock,
        bridge: PlaybackQueueBridge? = nil,
        automaticTicker: Bool = true,
        systemControlsEnabled: Bool = true,
        clientFactory: @escaping ClientFactory,
        historyFactory: @escaping HistoryFactory
    ) {
        self.engine = engine
        self.store = store
        self.clock = clock
        self.bridge = bridge ?? PlaybackQueueBridge()
        self.clientFactory = clientFactory
        self.historyFactory = historyFactory
        initialLoad = Task { try await store.load() }

        engine.onEvent = { [weak self] event in self?.receive(event) }
        if systemControlsEnabled {
            let controls = PlaybackSystemControls(bridge: self.bridge)
            controls.onBackground = { [weak self] in
                self?.onAppBackgrounded()
            }
            controls.onForeground = { [weak self] in
                self?.onAppForegrounded()
            }
            self.controls = controls
        }

        let commands = self.bridge.commands
        bridgeTask = Task { [weak self] in
            for await command in commands {
                guard !Task.isCancelled else { return }
                await self?.handle(command)
            }
        }

        if automaticTicker {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await clock.sleep(milliseconds: 500)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    self.tick()
                }
            }
        }
        Task { [weak self] in await self?.prepare() }
    }

    var isPlaying: Bool { state == .playing }

    var canRequestNext: Bool {
        queue.hasNext || (!queue.isRestricted && albumPage?.hasNextPage == true)
    }

    func prepare() async {
        guard !didPrepare else { return }
        do {
            let loaded = try await initialLoad.value
            guard !didPrepare else { return }
            didPrepare = true
            storageReady = true

            var restored = loaded.settings.dictionary
            let edited = settings.dictionary
            for key in editedSettingsKeys { restored[key] = edited[key] }
            settings = PlaybackSettings(json: restored)

            localProgress = loaded.progress
            pendingSync = loaded.pendingSync.map {
                var value = $0
                value.isRetry = true
                return value
            }
            // 旧版本或手工导入可能含同一声音多条记录；保留最新时间，
            // 时间相同时以数组中较后的快照为准，不比较播放位置。
            var unique: [PendingPlaybackSync] = []
            for entry in pendingSync {
                if let index = unique.firstIndex(where: {
                    $0.identity == entry.identity && $0.track.id == entry.track.id
                }) {
                    if unique[index].endedAtMs <= entry.endedAtMs {
                        unique[index] = entry
                    }
                } else {
                    unique.append(entry)
                }
            }
            pendingSync = unique.sorted { $0.endedAtMs < $1.endedAtMs }
            pendingSyncCount = pendingSync.count
            lastProgressTimestamp = max(
                localProgress.map(\.updatedAt).max() ?? 0,
                pendingSync.map(\.endedAtMs).max() ?? 0
            )
            engine.setSpeed(settings.speed)
            engine.setVolume(settings.volume)
            if !pendingSync.isEmpty || !editedSettingsKeys.isEmpty {
                persist()
                startSyncWorker()
            }
        } catch {
            guard !didPrepare else { return }
            didPrepare = true
            message = "本地播放状态读取失败，暂不能保存进度；请检查应用存储"
        }
    }

    func play(track: Track, resumePositionMs: Int64? = nil) async {
        await playQueue([track], index: 0, resumePositionMs: resumePositionMs)
    }

    func playInAlbum(
        track: Track, resumePositionMs: Int64? = nil
    ) async {
        let request = beginSelection()
        defer { finishSelection(request: request) }
        await prepare()
        guard request == playRequest else { return }

        do {
            let client = try await clientFactory()
            guard request == playRequest else { return }
            var selected = PlaybackQueue([track])
            var page: PlaybackAlbumPage?
            if !track.albumKey.isEmpty {
                do {
                    let located = try await client.locateAlbum(
                        albumID: track.albumKey, trackID: track.id
                    )
                    guard request == playRequest else { return }
                    if let located, let index = located.tracks.firstIndex(where: {
                        $0.id == track.id
                    }) {
                        selected = PlaybackQueue(located.tracks, index: index)
                        page = located
                    } else {
                        message = "未找到所在专辑页，按单集播放"
                    }
                } catch {
                    guard request == playRequest else { return }
                    message = "专辑定位失败，按单集播放"
                }
            }
            guard request == playRequest else { return }
            let audio = try await client.resolve(
                number: track.number, quality: settings.quality
            )
            guard request == playRequest else { return }
            try commitSelection(
                selected: selected, page: page, resume: resumePositionMs,
                request: request, client: client, resolved: audio
            )
        } catch {
            guard request == playRequest else { return }
            message = playbackMessage(error)
        }
    }

    func playQueue(
        _ tracks: [Track], index: Int, resumePositionMs: Int64? = nil
    ) async {
        guard tracks.indices.contains(index) else {
            message = "播放队列为空或索引无效"
            return
        }
        let selected = PlaybackQueue(tracks, index: index)
        await select(selected, page: nil, resume: resumePositionMs)
    }

    func next() async {
        guard queue.current != nil else { return }
        guard canRequestNext else {
            message = "已是最后一集"
            return
        }

        let request = beginSelection()
        defer { finishSelection(request: request) }
        var version = queueVersion
        var usePrefetch = true
        let source = activeItemID

        await prepare()
        guard request == playRequest else { return }
        if version != queueVersion, !canRequestNext {
            message = "已是最后一集"
            return
        }

        do {
            let client = try await clientFactory()
            guard request == playRequest else { return }

            while request == playRequest {
                if version != queueVersion {
                    // 范围已生效，旧队列、旧分页结果及旧预取都不能再使用。
                    version = queueVersion
                    usePrefetch = false
                    guard canRequestNext else {
                        message = "已是最后一集"
                        return
                    }
                }

                let original = queue
                let originalPage = albumPage

                if usePrefetch, let prefetch,
                   prefetch.source == source,
                   prefetch.identity == client.identity,
                   prefetch.quality == settings.quality {
                    usePrefetch = false
                    let age = clock.now() - prefetch.createdAt
                    if age >= 0, age <= 60_000 {
                        let candidate = try? await prefetch.task.value
                        guard request == playRequest else { return }
                        if version != queueVersion { continue }

                        // 等待本身可能跨过 TTL，采用结果前再次检查。
                        let completedAge = clock.now() - prefetch.createdAt
                        if let candidate,
                           completedAge >= 0, completedAge <= 60_000,
                           prefetch.source == activeItemID,
                           prefetch.quality == settings.quality {
                            try commitSelection(
                                selected: candidate.queue, page: candidate.page,
                                resume: nil, request: request, client: client,
                                resolved: candidate.audio
                            )
                            return
                        }
                    }
                }
                usePrefetch = false

                var selected = original
                var page = originalPage
                if selected.next() == nil {
                    guard !original.isRestricted,
                          let originalPage, originalPage.hasNextPage else {
                        message = "已是最后一集"
                        return
                    }
                    do {
                        let nextPage = try await client.loadAlbum(
                            albumID: originalPage.albumID,
                            page: originalPage.page + 1,
                            pageSize: originalPage.pageSize
                        )
                        guard request == playRequest else { return }
                        if version != queueVersion { continue }
                        guard nextPage.page == originalPage.page + 1,
                              !nextPage.tracks.isEmpty else {
                            message = "已是最后一集"
                            return
                        }
                        selected = PlaybackQueue(nextPage.tracks)
                        page = nextPage
                    } catch {
                        guard request == playRequest else { return }
                        if version != queueVersion { continue }
                        message = "已是最后一集"
                        return
                    }
                }

                guard let selectedTrack = selected.current else { return }
                do {
                    let audio = try await client.resolve(
                        number: selectedTrack.number, quality: settings.quality
                    )
                    guard request == playRequest else { return }
                    if version != queueVersion { continue }
                    try commitSelection(
                        selected: selected, page: page, resume: nil,
                        request: request, client: client, resolved: audio
                    )
                    return
                } catch {
                    guard request == playRequest else { return }
                    if version != queueVersion { continue }
                    throw error
                }
            }
        } catch {
            guard request == playRequest else { return }
            if version != queueVersion, !canRequestNext {
                message = "已是最后一集"
            } else {
                message = playbackMessage(error)
            }
        }
    }

    func previous() async {
        var selected = queue
        switch selected.previous(positionMs: engine.snapshot.positionMs) {
        case .restart:
            seekTo(0)
        case .selected:
            await select(selected, page: albumPage, resume: nil)
        }
    }

    /// 只改队列与索引，不换集；当前集落在范围外时索引归零，
    /// 当前声音及其播放或暂停状态保持不变。
    func setQueueRange(start: Int?, end: Int?) async {
        var selected = queue
        guard selected.setRange(start: start, end: end) else { return }
        queueVersion &+= 1
        queue = selected
        publishQueue()
        startPrefetch()
    }

    func toggle() {
        if state == .playing || state == .loading {
            pause()
        } else {
            resume()
        }
    }

    func pause() {
        // 自动续集尚未进入 next() 时也必须响应用户暂停。
        autoAdvanceRequest &+= 1
        if selectionPending {
            playRequest &+= 1
            selectionPending = false
        }
        guard activeItemID != nil else {
            if state == .loading {
                // 提交后的加载尚未建立有效 item 时，暂停也须淘汰迟到结果。
                playRequest &+= 1
                selectionPending = false
                state = .paused
            }
            return
        }
        engine.pause()
    }

    func resume() {
        guard let activeItemID, activeItemID == engine.snapshot.itemID,
              state != .failed else { return }
        do {
            try controls?.activate()
            if durationMs > 0 && positionMs >= durationMs {
                seekTo(0)
            }
            endingItem = nil
            engine.play()
        } catch {
            message = playbackMessage(error)
        }
    }

    func seekTo(_ positionMs: Int64) {
        guard activeItemID != nil else { return }
        endingItem = nil
        var target = max(0, positionMs)
        if durationMs > 0 { target = min(target, durationMs) }
        engine.seek(to: target)
        self.positionMs = target
        if let ledger = usageLedger, let identity = sessionIdentity {
            Task { await ledger.onSeek(identity: identity) }
        }
        // 即使暂停中回退，也保存新的明确位置，不按最大位置合并。
        if sessionStartedAt == nil, let sessionTrack {
            let now = nextProgressTimestamp()
            enqueueProgress(track: sessionTrack, started: now, ended: now)
        } else {
            syncProgress()
        }
        updateNowPlaying()
    }

    func skipBy(_ deltaMs: Int64) {
        let result = positionMs.addingReportingOverflow(deltaMs)
        seekTo(result.overflow ? (deltaMs > 0 ? Int64.max : 0) : result.partialValue)
    }

    func setSpeed(_ speed: Double) {
        settings.speed = PlaybackSettings.normalizeSpeed(speed)
        editedSettingsKeys.insert("speed")
        engine.setSpeed(settings.speed)
        if let ledger = usageLedger, let identity = sessionIdentity {
            let newSpeed = settings.speed
            Task { await ledger.onSpeedChanged(identity: identity, speed: newSpeed) }
        }
        persist()
        updateNowPlaying()
    }

    func setVolume(_ volume: Double) {
        settings.volume = PlaybackSettings.normalizeVolume(volume)
        editedSettingsKeys.insert("volume")
        engine.setVolume(settings.volume)
        persist()
    }

    func setSmartSkipEnabled(_ enabled: Bool) {
        settings.setTrim(
            enabled: enabled,
            intro: settings.introPermille,
            outro: settings.outroPermille,
            mode: "smart"
        )
        editedSettingsKeys.insert("skipTrim")
        editedSettingsKeys.insert("skipMode")
        if !enabled {
            activeSilenceIntervals = []
            lastSmartSkipTargetMs = -1
            if let scanner = smartSkipScanner {
                Task { await scanner.cancelActiveScan() }
            }
        }
        persist()
    }

    func prepareSmartSkip(
        localURL: URL,
        resourceKey: String,
        version: String = "1",
        parameters: SmartSkipParameters = .default
    ) async {
        guard settings.skipTrim, settings.skipMode == "smart",
              let scanner = smartSkipScanner,
              let itemID = activeItemID else {
            return
        }
        let key = SmartSkipCacheKey(
            resourceKey: resourceKey,
            resourceVersion: version,
            parameters: parameters
        )
        let intervals = await scanner.scanLocalFile(
            url: localURL, key: key, parameters: parameters
        )
        guard activeItemID == itemID else { return }
        activeSilenceIntervals = intervals
        lastSmartSkipTargetMs = -1
    }

    func setSoundEffect(_ preset: SoundEffectPreset) {
        engine.setSoundEffect(preset)
    }

    func setQuality(_ quality: String) {
        let normalized = PlaybackSettings.normalizeQuality(quality)
        let changed = settings.quality != normalized
        settings.quality = normalized
        editedSettingsKeys.insert("quality")
        persist()
        startPrefetch()
        if changed,
           track != nil,
           !queue.queue.isEmpty,
           state == .playing || state == .paused || state == .loading {
            let resumeMs = positionMs
            let shouldResumePlaying = state == .playing || state == .loading
            let currentQueue = queue.queue
            let currentIndex = queue.index
            Task { [weak self] in
                guard let self else { return }
                await self.playQueue(currentQueue, index: currentIndex, resumePositionMs: resumeMs)
                if !shouldResumePlaying {
                    self.pause()
                }
            }
        }
    }

    func setSkipTrim(
        enabled: Bool? = nil, intro: Int? = nil,
        outro: Int? = nil, mode: String? = nil
    ) {
        settings.setTrim(
            enabled: enabled ?? settings.skipTrim,
            intro: intro ?? settings.introPermille,
            outro: outro ?? settings.outroPermille,
            mode: mode ?? settings.skipMode
        )
        editedSettingsKeys.formUnion([
            "skipTrim", "skipMode", "introPermille", "outroPermille"
        ])
        persist()
    }

    func migrateLegacySmartSkipIfNeeded() {
        guard settings.skipTrim, settings.skipMode != "manual" else { return }
        setSkipTrim(
            enabled: true,
            intro: settings.introPermille,
            outro: settings.outroPermille,
            mode: "manual"
        )
    }

    func skipTrimPercentLabel(permille: Int) -> String {
        let clamped = max(0, permille)
        let percentText = String(format: "%.1f%%", Double(clamped) / 10.0)
        guard durationMs > 0 else { return percentText }
        let seconds = Int((Double(durationMs) * Double(clamped) / 1_000_000.0).rounded())
        return "\(percentText) · 约 \(seconds) 秒"
    }

    func introSeekMs(trackSeconds: Double, currentDurationMs: Int64? = nil) -> Int64 {
        guard settings.skipTrim, settings.skipMode == "manual",
              settings.introPermille > 0 else { return 0 }
        let basis = trackSeconds > 1
            ? playbackMilliseconds(trackSeconds)
            : max(0, currentDurationMs ?? durationMs)
        return Int64(Double(basis) * Double(settings.introPermille) / 1_000)
    }

    func setSleepTimer(minutes: Int?) {
        guard let minutes else {
            sleepAtMillis = nil
            return
        }
        guard minutes > 0, minutes <= 10_080 else {
            message = "定时时长须为 1 至 10080 分钟"
            return
        }
        sleepAtMillis = clock.now() + Int64(minutes) * 60_000
        message = "\(minutes) 分钟后停止播放"
    }

    func stop() {
        autoAdvanceRequest &+= 1
        playRequest &+= 1
        selectionPending = false
        syncProgress(endInterval: true)
        saveLocalProgress()
        activeItemID = nil
        sessionTrack = nil
        sessionClient = nil
        sessionIdentity = nil
        sessionStartedAt = nil
        albumPage = nil
        prefetch?.task.cancel()
        prefetch = nil
        streamRecoveryTask?.cancel()
        streamRecoveryTask = nil
        streamRecoveryAttempts = 0
        streamRecoveryTrackID = nil
        engine.stop()
        track = nil
        actualQuality = nil
        state = .idle
        positionMs = 0
        durationMs = 0
        queue = PlaybackQueue()
        sleepAtMillis = nil
        endingItem = nil
        lastEndedItem = nil
        publishQueue()
        do {
            try controls?.clear()
        } catch {
            message = playbackMessage(error)
        }
    }

    func clearMessage() { message = nil }

    /// 返回续播候选，不替调用方 seek。
    /// 有时间戳时选择较新记录；相同时间或云端时间未知时优先云端。
    /// 调用方仍可用 localRecord 显式选择本地候选。
    /// 两参数都空时，仅已登录分支透传 B1 invalidHistory；
    /// 匿名分支直接返回本地候选，不调用云端，也不抛该异常。
    func progress(
        albumId: String = "", trackId: String = ""
    ) async throws -> HistoryRecord? {
        await prepare()
        let client = try await clientFactory()
        let identity = client.identity == "anonymous" ? nil : client.identity
        let local = localRecord(identity: identity, albumId: albumId, trackId: trackId)
        guard let identity else { return local }
        let history = try await historyFactory(identity)
        let remote = try await history.progress(albumId: albumId, trackId: trackId)
        guard let remote else { return local }
        guard let local, remote.updatedAt > 0 else { return remote }
        return local.updatedAt > remote.updatedAt ? local : remote
    }

    func localRecord(
        identity: String?, albumId: String = "", trackId: String = ""
    ) -> HistoryRecord? {
        let album = albumId.hasPrefix("xmly:") ? String(albumId.dropFirst(5)) : albumId
        let number = trackId.hasPrefix("xmly:") ? String(trackId.dropFirst(5)) : trackId
        return localProgress.filter {
            $0.identity == identity
                && (album.isEmpty || $0.track.albumKey == album)
                && (number.isEmpty || $0.track.number == number)
        }.max { $0.updatedAt < $1.updatedAt }?.record
    }

    func syncProgress(endInterval: Bool = false) {
        guard let sessionTrack, let started = sessionStartedAt, started > 0 else {
            return
        }
        let ended = max(started, nextProgressTimestamp())
        enqueueProgress(track: sessionTrack, started: started, ended: ended)
        sessionStartedAt = endInterval ? nil : ended
        lastSyncAt = clock.now()
    }

    func onAppBackgrounded() {
        controls?.beginBackgroundSubmission()
        syncProgress()
        saveLocalProgress()
        persist()
        startSyncWorker()
        if syncTask == nil {
            let saving = persistenceTask
            Task { [weak self] in
                _ = await saving?.value
                self?.controls?.endBackgroundSubmission()
            }
        }
    }

    func onAppForegrounded() {
        Task { [weak self] in
            guard let self else { return }
            await self.prepare()
            self.tick()
            self.startSyncWorker()
        }
    }

    /// 时钟驱动入口；测试可关闭自动 ticker 并手动调用。
    func tick() {
        let now = clock.now()
        if let deadline = sleepAtMillis, now >= deadline {
            stop()
            message = "定时关闭已触发"
            return
        }
        guard activeItemID == engine.snapshot.itemID, activeItemID != nil else {
            return
        }
        positionMs = engine.snapshot.positionMs
        if engine.snapshot.durationMs > 0 {
            durationMs = engine.snapshot.durationMs
        }
        guard state == .playing else {
            updateNowPlaying()
            return
        }

        let outro = settings.skipTrim && settings.skipMode == "manual"
            ? Int64(Double(durationMs) * Double(settings.outroPermille) / 1_000)
            : 0
        if outro > 0, durationMs > outro + 2_000,
           positionMs >= durationMs - outro, let activeItemID {
            handleEnd(activeItemID)
            return
        }
        if now - lastSyncAt >= 60_000 {
            syncProgress()
        }
        if now - lastLocalSaveAt >= 5_000 {
            saveLocalProgress()
            lastLocalSaveAt = now
        }
        updateNowPlaying()
    }

    /// 测试及受控退出使用；正常 UI 不阻塞等待网络。
    func flush() async {
        await prepare()
        while let task = syncTask { await task.value }
        _ = await persistenceTask?.value
    }

    private func select(
        _ selected: PlaybackQueue, page: PlaybackAlbumPage?, resume: Int64?
    ) async {
        guard let track = selected.current else { return }
        let request = beginSelection()
        defer { finishSelection(request: request) }
        await prepare()
        guard request == playRequest else { return }
        do {
            let client = try await clientFactory()
            guard request == playRequest else { return }
            let audio = try await client.resolve(
                number: track.number, quality: settings.quality
            )
            guard request == playRequest else { return }
            try commitSelection(
                selected: selected, page: page, resume: resume,
                request: request, client: client, resolved: audio
            )
        } catch {
            guard request == playRequest else { return }
            message = playbackMessage(error)
        }
    }

    private func beginSelection() -> UInt64 {
        playRequest &+= 1
        selectionPending = true
        message = nil
        return playRequest
    }

    private func finishSelection(request: UInt64) {
        // 旧请求退出时不能清除较新请求的 pending 标志。
        // pause/stop 已负责清除它们所淘汰请求的标志。
        guard request == playRequest else { return }
        selectionPending = false
    }

    private func commitSelection(
        selected: PlaybackQueue, page: PlaybackAlbumPage?, resume: Int64?,
        request: UInt64, client: any PlaybackClient, resolved: ResolvedAudio
    ) throws {
        guard request == playRequest, let selectedTrack = selected.current else {
            return
        }
        // 解析结果无效也属于提交前失败，不能影响当前播放。
        guard resolved.track.id == selectedTrack.id else {
            throw PlaybackFailure(message: "播放解析返回了不同的声音")
        }
        guard let url = URL(string: resolved.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PlaybackFailure(message: "播放解析返回了无效地址")
        }

        detachCurrent()
        prefetch?.task.cancel()
        prefetch = nil
        track = selectedTrack
        state = .loading
        positionMs = 0
        durationMs = playbackMilliseconds(selectedTrack.duration)
        resolveAndStart(
            selected, page: page, resume: resume,
            request: request, client: client, resolved: resolved
        )
    }

    private func detachCurrent() {
        syncProgress(endInterval: true)
        saveLocalProgress()
        activeItemID = nil
        sessionTrack = nil
        sessionClient = nil
        sessionIdentity = nil
        sessionStartedAt = nil
        engine.stop()
    }

    private func resolveAndStart(
        _ selected: PlaybackQueue, page: PlaybackAlbumPage?, resume: Int64?,
        request: UInt64, client: any PlaybackClient,
        resolved: ResolvedAudio
    ) {
        guard request == playRequest, let catalogueTrack = selected.current else {
            return
        }
        queue = selected
        albumPage = page
        publishQueue()

        do {
            let audio = resolved
            actualQuality = audio.actualQuality
            guard let url = URL(string: audio.url),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw PlaybackFailure(message: "播放解析返回了无效地址")
            }

            let duration = playbackMilliseconds(
                audio.track.duration > 0 ? audio.track.duration : catalogueTrack.duration
            )
            durationMs = duration
            // 显式 0 也是调用方的续播决定，不替换成 intro。
            let start = resume.map { max(0, $0) } ?? introSeekMs(
                trackSeconds: audio.track.duration,
                currentDurationMs: duration
            )
            let item = PlaybackItem(
                url: url, headers: audio.headers,
                durationMs: duration, startPositionMs: start
            )

            try controls?.activate()
            let resolvedTrack = audio.track
            let mergedArtist = resolvedTrack.artist.isEmpty ? catalogueTrack.artist : resolvedTrack.artist
            let mergedAlbum = resolvedTrack.album.isEmpty ? catalogueTrack.album : resolvedTrack.album
            let mergedCover = resolvedTrack.coverUrl ?? catalogueTrack.coverUrl
            let finalTrack: Track
            if mergedArtist != resolvedTrack.artist || mergedAlbum != resolvedTrack.album || mergedCover != resolvedTrack.coverUrl,
               let merged = try? Track(
                rawId: resolvedTrack.id,
                title: resolvedTrack.title,
                artist: mergedArtist,
                album: mergedAlbum,
                albumId: resolvedTrack.albumKey,
                duration: resolvedTrack.duration,
                orderNo: resolvedTrack.orderNo,
                episode: resolvedTrack.episode,
                isPaid: resolvedTrack.isPaid,
                isAuthorized: resolvedTrack.isAuthorized,
                coverUrl: mergedCover,
                intro: resolvedTrack.intro,
                raw: resolvedTrack.raw
               ) {
                finalTrack = merged
            } else {
                finalTrack = resolvedTrack
            }
            track = finalTrack
            sessionTrack = finalTrack
            sessionClient = client
            sessionIdentity = client.identity == "anonymous" ? nil : client.identity
            currentRequiresReward = audio.requiresReward
            activeSilenceIntervals = []
            lastSmartSkipTargetMs = -1
            if let scanner = smartSkipScanner {
                Task { await scanner.cancelActiveScan() }
            }
            activeItemID = item.id
            endingItem = nil
            sessionStartedAt = nil
            positionMs = item.startPositionMs
            lastSyncAt = clock.now()
            lastLocalSaveAt = clock.now()
            engine.setSpeed(settings.speed)
            engine.setVolume(settings.volume)
            try engine.load(item)
            selectionPending = false
            updateNowPlaying()
            startPrefetch()
        } catch {
            selectionFailed(error, request: request)
        }
    }

    private func selectionFailed(_ error: Error, request: UInt64) {
        guard request == playRequest else { return }
        selectionPending = false
        syncProgress(endInterval: true)
        activeItemID = nil
        sessionTrack = nil
        sessionClient = nil
        sessionIdentity = nil
        sessionStartedAt = nil
        engine.stop()
        state = .failed
        message = playbackMessage(error)
        updateNowPlaying()
    }

    private func receive(_ event: PlaybackEngineEvent) {
        switch event {
        case let .snapshot(snapshot):
            guard let id = activeItemID, snapshot.itemID == id else { return }
            state = snapshot.state
            positionMs = snapshot.positionMs
            if snapshot.durationMs > 0 { durationMs = snapshot.durationMs }

            if state == .playing, sessionStartedAt == nil {
                sessionStartedAt = max(1, clock.now())
                lastSyncAt = clock.now()
                // 切集首次真正开始时立即落盘并登记历史。
                syncProgress()
            } else if state == .paused || state == .failed || state == .ended {
                syncProgress(endInterval: true)
            }
            if let ledger = usageLedger, let identity = sessionIdentity {
                let playingNow = (state == .playing)
                let requiresReward = currentRequiresReward
                Task {
                    await ledger.onPlaybackStateChanged(
                        identity: identity,
                        isPlaying: playingNow,
                        requiresReward: requiresReward
                    )
                }
            }
            if state == .playing,
               settings.skipTrim,
               settings.skipMode == "smart",
               !activeSilenceIntervals.isEmpty,
               let target = SilenceIntervalDetector.skipTarget(
                   at: positionMs, in: activeSilenceIntervals
               ),
               target != lastSmartSkipTargetMs {
                lastSmartSkipTargetMs = target
                seekTo(target)
            }
            if let failure = snapshot.failure { message = failure.message }
            if state == .playing, let tid = track?.id {
                if streamRecoveryTrackID != tid {
                    streamRecoveryTrackID = tid
                    streamRecoveryAttempts = 0
                }
            }
            // 对齐上游 42ba389：播放中途因签名 URL 过期或网络断连失败时，
            // 自动重新解析流地址并从断点续播（每集最多 3 次）。
            if state == .failed,
               sessionStartedAt != nil,
               let currentTrack = track,
               !queue.queue.isEmpty,
               streamRecoveryAttempts < 3 {
                if streamRecoveryTrackID != currentTrack.id {
                    streamRecoveryTrackID = currentTrack.id
                    streamRecoveryAttempts = 0
                }
                streamRecoveryAttempts += 1
                let resumeMs = positionMs
                let currentQueue = queue.queue
                let currentIndex = queue.index
                let attemptTrackId = currentTrack.id
                streamRecoveryTask?.cancel()
                streamRecoveryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard let self, !Task.isCancelled,
                          self.track?.id == attemptTrackId,
                          self.state == .failed else { return }
                    await self.playQueue(currentQueue, index: currentIndex, resumePositionMs: resumeMs)
                }
            }
            updateNowPlaying()
        case let .ended(id):
            handleEnd(id)
        }
    }

    private func handleEnd(_ id: UUID) {
        guard id == activeItemID, endingItem != id else { return }
        let now = clock.now()
        if lastEndedItem == id, now - lastAdvanceAt < 2_000 { return }
        endingItem = id
        lastEndedItem = id
        lastAdvanceAt = now
        syncProgress(endInterval: true)
        engine.pause()
        guard !selectionPending else { return }
        guard canRequestNext else {
            message = "已是最后一集"
            return
        }
        let request = playRequest
        let advanceRequest = autoAdvanceRequest
        Task { [weak self] in
            guard let self, self.playRequest == request,
                  self.autoAdvanceRequest == advanceRequest,
                  !self.selectionPending,
                  self.activeItemID == id else { return }
            await self.next()
        }
    }

    private func startPrefetch() {
        prefetch?.task.cancel()
        prefetch = nil
        guard let source = activeItemID, let client = sessionClient,
              canRequestNext else { return }
        let original = queue
        let page = albumPage
        let quality = settings.quality

        let task = Task<PreparedNext?, Error> {
            var selected = original
            var nextPage = page
            if selected.next() == nil {
                guard !original.isRestricted, let page, page.hasNextPage else {
                    return nil
                }
                let loaded = try await client.loadAlbum(
                    albumID: page.albumID,
                    page: page.page + 1, pageSize: page.pageSize
                )
                try Task.checkCancellation()
                guard loaded.page == page.page + 1, !loaded.tracks.isEmpty else {
                    return nil
                }
                nextPage = loaded
                selected = PlaybackQueue(loaded.tracks)
            }
            guard let nextTrack = selected.current else { return nil }
            try Task.checkCancellation()
            // 仅预取一集。付费/debit 仍完全由既有 resolve 实现处理。
            let audio = try await client.resolve(
                number: nextTrack.number, quality: quality
            )
            try Task.checkCancellation()
            guard audio.track.id == nextTrack.id else {
                throw PlaybackFailure(message: "下一集解析返回了不同的声音")
            }
            return PreparedNext(queue: selected, page: nextPage, audio: audio)
        }
        prefetch = Prefetch(
            source: source, identity: client.identity, quality: quality,
            createdAt: clock.now(), task: task
        )
    }

    private func nextProgressTimestamp() -> Int64 {
        let now = max(1, clock.now())
        lastProgressTimestamp = max(now, lastProgressTimestamp + 1)
        return lastProgressTimestamp
    }

    private func enqueueProgress(track: Track, started: Int64, ended: Int64) {
        let position = Double(max(0, engine.snapshot.positionMs)) / 1_000
        replaceLocal(LocalPlaybackProgress(
            identity: sessionIdentity, track: track,
            positionSeconds: position, updatedAt: ended
        ))
        if let identity = sessionIdentity, !track.albumKey.isEmpty {
            // 正在提交的旧快照由 worker 局部持有。待提交槽只保留最新快照；
            // 旧请求完成时按 UUID 删除，不能误删后来的新进度。
            pendingSync.removeAll {
                $0.identity == identity && $0.track.id == track.id
            }
            pendingSync.append(PendingPlaybackSync(
                identity: identity, track: track,
                positionSeconds: position,
                startedAtMs: max(1, started), endedAtMs: max(started, ended)
            ))
            pendingSyncCount = pendingSync.count
        }
        persist()
        startSyncWorker()
    }

    private func replaceLocal(_ progress: LocalPlaybackProgress) {
        localProgress.removeAll {
            $0.identity == progress.identity && $0.track.id == progress.track.id
        }
        localProgress.append(progress)
    }

    private func saveLocalProgress() {
        guard let sessionTrack else { return }
        replaceLocal(LocalPlaybackProgress(
            identity: sessionIdentity, track: sessionTrack,
            positionSeconds: Double(max(0, engine.snapshot.positionMs)) / 1_000,
            updatedAt: nextProgressTimestamp()
        ))
        persist()
    }

    @discardableResult
    private func persist() -> Task<Bool, Never>? {
        guard storageReady else { return nil }
        let snapshot = PlaybackStoredState(
            settings: settings, progress: localProgress, pendingSync: pendingSync
        )
        let previous = persistenceTask
        let store = self.store
        let task = Task { [weak self] in
            _ = await previous?.value
            do {
                try await store.save(snapshot)
                return true
            } catch {
                self?.message = "本地播放状态保存失败，进度将在下次保存时重试"
                return false
            }
        }
        persistenceTask = task
        return task
    }

    private func startSyncWorker() {
        guard storageReady, syncTask == nil, !pendingSync.isEmpty else { return }
        syncTask = Task { [weak self] in
            await self?.drainSync()
        }
    }

    private func drainSync() async {
        defer {
            syncTask = nil
            controls?.endBackgroundSubmission()
        }
        var attempted: Set<UUID> = []

        while let candidate = pendingSync.first(where: {
            !attempted.contains($0.id)
        }) {
            attempted.insert(candidate.id)
            // 网络提交必须在快照持久化之后；磁盘故障时保留内存队列等待重试。
            guard await persistenceTask?.value == true else { return }
            guard pendingSync.contains(where: { $0.id == candidate.id }) else {
                continue
            }

            do {
                let history = try await historyFactory(candidate.identity)
                let remote = try await history.progress(
                    albumId: candidate.track.albumKey,
                    trackId: candidate.track.id
                )
                guard pendingSync.contains(where: { $0.id == candidate.id }) else {
                    continue
                }

                // 跨设备策略：
                // 1. 云端时间较新或同时间，云端胜出，位置可以更小。
                // 2. 重放历史待同步项且云端时间未知，保守保留云端。
                // 3. 新的本地明确操作可覆盖时间未知的云端记录。
                let remoteWins = remote.map {
                    ($0.updatedAt > 0 && $0.updatedAt >= candidate.endedAtMs)
                        || ($0.updatedAt <= 0 && candidate.isRetry)
                } ?? false

                if !remoteWins {
                    // 整个 session 只有这一个入口调用 sync。
                    // B1 的 XmlyTrackWriteGate 继续负责跨 client 互斥。
                    try await history.sync(
                        track: candidate.track,
                        positionSeconds: candidate.positionSeconds,
                        startedAtMs: candidate.startedAtMs,
                        endedAtMs: candidate.endedAtMs
                    )
                }

                pendingSync.removeAll { $0.id == candidate.id }
                pendingSyncCount = pendingSync.count
                let saved = persist()
                _ = await saved?.value
            } catch {
                if let index = pendingSync.firstIndex(where: {
                    $0.id == candidate.id
                }) {
                    pendingSync[index].isRetry = true
                }
                if isPlaybackAuthenticationError(error) {
                    message = "登录信息已失效，播放进度未同步"
                }
                let saved = persist()
                _ = await saved?.value
                // 本轮不循环重试同一 UUID；下次前台或新快照触发新一轮。
            }
        }
    }

    private func publishQueue() {
        bridge.publish(snapshot: queue.snapshot)
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        controls?.update(
            track: track, state: state,
            positionMs: positionMs, durationMs: durationMs,
            speed: settings.speed, hasNext: canRequestNext
        )
    }

    private func handle(_ command: PlaybackQueueBridge.Command) async {
        switch command {
        case .next: await next()
        case .previous: await previous()
        case .play: resume()
        case .pause: pause()
        case .toggle: toggle()
        case let .seek(position): seekTo(position)
        }
    }

    deinit {
        ticker?.cancel()
        bridgeTask?.cancel()
        prefetch?.task.cancel()
    }
}
