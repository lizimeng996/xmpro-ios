import SwiftUI

@MainActor
struct UserPageView: View {
    let uid: String
    let service: XmlyExperienceService

    @Environment(\.xmPalette) private var palette

    @State private var page: UserPage?
    @State private var loading = true
    @State private var error: XmlyError?
    @State private var paginationNotice = false

    var body: some View {
        LoadStateView(state: loadState) {
            if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        profileHeaderCard(page)

                        VStack(alignment: .leading, spacing: 12) {
                            XMSectionHeader(
                                title: "主播作品",
                                badge: "\(page.totalAlbums) 部"
                            )

                            if page.albums.isEmpty {
                                XMEmptyState(systemImage: "square.stack", title: "暂无作品")
                                    .padding(.vertical, 20)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(page.albums.enumerated()), id: \.offset) { idx, album in
                                        NavigationLink {
                                            AlbumDetailView(albumId: album.id, initialAlbum: album)
                                        } label: {
                                            XMMediaRow(
                                                coverUrl: album.coverUrl,
                                                title: album.title,
                                                subtitle: album.intro.isEmpty ? nil : album.intro,
                                                detail: "\(album.total) 集",
                                                coverSize: 60
                                            ) {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 12)
                                        }
                                        .buttonStyle(.plain)

                                        if idx < page.albums.count - 1 {
                                            Divider().padding(.leading, 88).opacity(0.6)
                                        }
                                    }
                                }
                                .xmCard(cornerRadius: XMMetrics.cardRadius)
                            }
                        }

                        if page.totalAlbums > page.albums.count {
                            Button("更多作品分页敬请期待") {
                                paginationNotice = true
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(XMMetrics.pagePadding)
                }
                .scrollIndicators(.hidden)
                .xmSoftScrollEdge()
            }
        }
        .xmPageBackground()
        .navigationTitle(page?.nickname.isEmpty == false ? page!.nickname : "主播")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: uid) { await load() }
        .alert("作品分页待后续版本", isPresented: $paginationNotice) {
            Button("知道了", role: .cancel) {}
        }
    }

    private func profileHeaderCard(_ page: UserPage) -> some View {
        VStack(spacing: 16) {
            XMArtwork(url: page.avatarUrl, cornerRadius: 44, symbol: "person.fill")
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            VStack(spacing: 5) {
                Text(page.nickname.isEmpty ? "主播" : page.nickname)
                    .font(.title3.weight(.bold))
                if !page.intro.isEmpty {
                    Text(page.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }

            HStack(spacing: 0) {
                statCell(value: "\(page.following)", label: "关注")
                Divider().frame(height: 24)
                statCell(value: XMDesign.formatCount(Int64(page.followers)), label: "粉丝")
                Divider().frame(height: 24)
                statCell(value: "\(page.totalAlbums)", label: "专辑")
            }
            .padding(.vertical, 10)
            .background(palette.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(20)
        .xmCard(cornerRadius: XMMetrics.cardRadius)
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadState: LoadState {
        if loading { return .loading }
        if let error {
            return .error(error, retry: { Task { await load() } })
        }
        return .idle
    }

    private func load() async {
        loading = true
        error = nil
        do {
            page = try await service.userPage(uid: uid)
        } catch {
            self.error = s4Error(error, fallback: "主播资料加载失败，请重试")
        }
        loading = false
    }
}
