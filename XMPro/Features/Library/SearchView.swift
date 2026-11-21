// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@MainActor
struct SearchView: View {
    var onOpenPlayer: (() -> Void)? = nil

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var query = ""
    @State private var kind: SearchPage.Kind = .album
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var page = 1
    @State private var total = 0
    @State private var loading = false
    @State private var hasSearched = false
    @State private var error: XmlyError?
    @State private var notice: String?

    private let hotKeywords = ["三体", "郭德纲", "明朝那些事儿", "凡人修仙传", "盗墓笔记", "白夜行", "绍宋"]

    var body: some View {
        VStack(spacing: 0) {
            if hasSearched {
                Picker("搜索类型", selection: $kind) {
                    Text("专辑").tag(SearchPage.Kind.album)
                    Text("声音").tag(SearchPage.Kind.track)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, XMMetrics.pagePadding)
                .padding(.vertical, 10)
            }

            contentBody
        }
        .xmPageBackground()
        .xmToast($notice)
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "专辑名、主播或声音关键词")
        .onSubmit(of: .search) {
            Task { await search(reset: true) }
        }
        .onChange(of: query) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                albums = []
                tracks = []
                total = 0
                hasSearched = false
                error = nil
            }
        }
        .onChange(of: kind) { _, _ in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await search(reset: true) }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if !hasSearched {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    XMSectionHeader(title: "热门搜索")

                    XMFlowLayout(spacing: 8, lineSpacing: 10) {
                        ForEach(hotKeywords, id: \.self) { word in
                            XMChip(title: word, selected: false, systemImage: "flame.fill") {
                                query = word
                                Task { await search(reset: true) }
                            }
                        }
                    }
                }
                .padding(XMMetrics.pagePadding)
            }
            .xmPageBackground()
        } else if loading && currentIsEmpty {
            Spacer()
            ProgressView("正在搜索…")
                .font(.subheadline)
            Spacer()
        } else if let error, currentIsEmpty {
            XMEmptyState(
                systemImage: "wifi.exclamationmark",
                title: "搜索失败",
                message: error.message
            ) {
                Button("重试") { Task { await search(reset: true) } }
                    .xmProminentButton()
            }
        } else if currentIsEmpty {
            XMEmptyState(
                systemImage: "magnifyingglass",
                title: kind == .album ? "未找到相关专辑" : "未找到相关声音",
                message: "换个关键词试试看"
            )
        } else {
            List {
                if kind == .album {
                    Section {
                        ForEach(albums, id: \.id) { album in
                            NavigationLink {
                                AlbumDetailView(
                                    albumId: album.id,
                                    initialAlbum: album,
                                    onOpenPlayer: onOpenPlayer
                                )
                            } label: {
                                XMMediaRow(
                                    coverUrl: album.coverUrl,
                                    title: album.title,
                                    subtitle: album.total > 0 ? "\(album.artist) · \(album.total) 集" : album.artist,
                                    detail: album.intro.isEmpty ? nil : album.intro
                                )
                            }
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("共 \(total) 张专辑")
                    }

                    if albums.count < total {
                        loadMoreRow(label: loading ? "加载中…" : "加载更多专辑")
                    }
                } else {
                    Section {
                        ForEach(tracks, id: \.id) { track in
                            let isCurrent = dependencies.playbackSession.track?.id == track.id
                            let isPlaying = isCurrent && dependencies.playbackSession.isPlaying
                            Button {
                                Task {
                                    await dependencies.playbackSession.play(track: track)
                                    notice = "已开始播放：\(track.title)"
                                    onOpenPlayer?()
                                }
                            } label: {
                                XMMediaRow(
                                    coverUrl: track.coverUrl,
                                    title: track.title,
                                    subtitle: track.album.isEmpty ? track.artist : "\(track.artist) · \(track.album)",
                                    highlighted: isCurrent
                                ) {
                                    if isCurrent {
                                        XMNowPlayingIndicator(isPlaying: isPlaying)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("共 \(total) 条声音")
                    }

                    if tracks.count < total {
                        loadMoreRow(label: loading ? "加载中…" : "加载更多声音")
                    }
                }
            }
            .listStyle(.plain)
            .xmPageBackground()
        }
    }

    private func loadMoreRow(label: String) -> some View {
        HStack {
            Spacer()
            Button(label) {
                Task { await search(reset: false) }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.accent)
            .disabled(loading)
            Spacer()
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var currentIsEmpty: Bool {
        kind == .album ? albums.isEmpty : tracks.isEmpty
    }

    private func search(reset: Bool) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        loading = true
        error = nil
        notice = nil
        if reset {
            page = 1
            albums = []
            tracks = []
            total = 0
        } else {
            page += 1
        }
        hasSearched = true

        do {
            let client = try await dependencies.makeCurrentClient()
            let result = try await client.search(
                query: keyword,
                kind: kind.rawValue,
                page: page
            )
            total = result.total
            if kind == .album {
                albums.append(contentsOf: result.albums)
            } else {
                tracks.append(contentsOf: result.tracks)
            }
        } catch {
            self.error = s4Error(error, fallback: "搜索失败，请检查网络后重试")
            if !reset { page = max(1, page - 1) }
        }
        loading = false
    }
}
