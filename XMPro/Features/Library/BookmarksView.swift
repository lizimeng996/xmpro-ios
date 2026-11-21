import SwiftUI

@MainActor
struct BookmarksView: View {
    let service: XmlyBookmarkService
    let revision: Int
    let onSelect: (Bookmark) -> Void

    @Environment(\.xmPalette) private var palette
    @State private var bookmarks: [Bookmark] = []
    @State private var loading = true
    @State private var error: XmlyError?
    @State private var notice: String?

    init(
        service: XmlyBookmarkService,
        revision: Int = 0,
        onSelect: @escaping (Bookmark) -> Void
    ) {
        self.service = service
        self.revision = revision
        self.onSelect = onSelect
    }

    var body: some View {
        LoadStateView(state: contentState) {
            List {
                ForEach(bookmarks, id: \.track.id) { bookmark in
                    Button {
                        onSelect(bookmark)
                    } label: {
                        XMMediaRow(
                            coverUrl: bookmark.track.coverUrl,
                            title: bookmark.track.title.isEmpty ? "未命名声音" : bookmark.track.title,
                            subtitle: bookmark.track.artist,
                            detail: formatTimestamp(bookmark.createdAt)
                        ) {
                            XMTag(text: XMDesign.clock(Int(bookmark.positionMs / 1_000)))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) {
                            Task { await remove(bookmark) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .xmPageBackground()
            .refreshable { await reload() }
        }
        .xmPageBackground()
        .xmToast($notice)
        .navigationTitle("书签")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: revision) { await reload() }
    }

    private var contentState: LoadState {
        if loading && bookmarks.isEmpty { return .loading }
        if let error, bookmarks.isEmpty {
            return .error(error, retry: { Task { await reload() } })
        }
        if bookmarks.isEmpty { return .empty(message: "暂无书签") }
        return .idle
    }

    private func reload() async {
        loading = true
        bookmarks = await service.list()
        loading = false
        error = nil
    }

    private func remove(_ bookmark: Bookmark) async {
        do {
            bookmarks = try await service.remove(trackId: bookmark.track.id)
            error = nil
            notice = "已删除书签"
        } catch {
            self.error = s4Error(error, fallback: "删除书签失败，请重试")
            notice = self.error?.message
        }
    }

    private func formatTimestamp(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(millis) / 1_000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
