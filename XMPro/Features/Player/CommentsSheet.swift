import SwiftUI

@MainActor
struct CommentsSheet: View {
    @ObservedObject var session: CommentsSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.xmPalette) private var palette

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error = session.error {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(palette.accent)
                        Text(error.message)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("重试") {
                            Task { await session.retry() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .disabled(session.loading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(palette.accentSoft)
                }

                LoadStateView(state: loadState) {
                    List {
                        ForEach(Array(session.comments.enumerated()), id: \.offset) { _, comment in
                            commentRow(comment)
                                .listRowBackground(Color.clear)
                        }

                        if session.hasMore {
                            HStack {
                                Spacer()
                                if session.loading {
                                    ProgressView()
                                } else if session.error == nil {
                                    Text("加载更多评论…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Button("重试加载") {
                                        Task { await session.loadMore() }
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(palette.accent)
                                }
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                guard session.error == nil else { return }
                                Task { await session.loadMore() }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .xmPageBackground()
                }
            }
            .xmPageBackground()
            .navigationTitle("评论（\(session.total)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var loadState: LoadState {
        if session.loading && session.comments.isEmpty { return .loading }
        if session.comments.isEmpty { return .empty(message: "暂无评论") }
        return .idle
    }

    private func commentRow(_ comment: Comment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                XMArtwork(url: comment.avatarUrl, cornerRadius: 18, symbol: "person.fill")
                    .frame(width: 36, height: 36)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.nickname.isEmpty ? "听友" : comment.nickname)
                        .font(.subheadline.weight(.semibold))
                    if !comment.createdAt.isEmpty {
                        Text(comment.createdAt)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if comment.likes > 0 {
                    Label("\(comment.likes)", systemImage: "hand.thumbsup.fill")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.fill, in: Capsule())
                }
            }

            Text(comment.content)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(3)

            if let reply = comment.replies.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(reply.nickname.isEmpty ? "听友" : reply.nickname)：\(reply.content)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if comment.replyCount > 1 {
                        Text("共 \(comment.replyCount) 条回复")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(palette.accent)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.vertical, 6)
    }
}
