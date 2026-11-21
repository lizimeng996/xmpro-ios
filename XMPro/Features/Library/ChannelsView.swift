// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@MainActor
struct ChannelsView: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.xmPalette) private var palette

    @State private var channels: [ChannelItem] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task { await syncRemote() }
                } label: {
                    HStack {
                        XMIconBadge(systemImage: "arrow.triangle.2.circlepath", color: palette.accent)
                        Text(busy ? "正在同步远端频道…" : "同步远端最新频道")
                            .foregroundStyle(.primary)
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
            } footer: {
                Text("关闭的频道不会显示在首页顶部；点击右上角「编辑」可拖拽调整顺序。")
            }

            Section {
                ForEach(channels) { channel in
                    Toggle(isOn: Binding(
                        get: { channel.enabled },
                        set: { newValue in
                            Task { await toggle(id: channel.id, enabled: newValue) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.title)
                                .foregroundStyle(channel.enabled ? Color.primary : Color.secondary)
                            Text("ID \(channel.id)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .onMove { from, to in
                    guard let source = from.first else { return }
                    let destination = to > source ? to - 1 : to
                    Task { await move(from: source, to: destination) }
                }
            } header: {
                Text("首页频道（\(channels.filter(\.enabled).count) / \(channels.count) 已启用）")
            }
        }
        .listStyle(.insetGrouped)
        .xmPageBackground()
        .xmToast($message)
        .navigationTitle("频道管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .task(id: dependencies.accountRevision) {
            channels = await dependencies.channelService.loadSavedChannels()
        }
    }

    private func toggle(id: String, enabled: Bool) async {
        do {
            channels = try await dependencies.channelService.setEnabled(id: id, enabled: enabled)
        } catch {
            message = "保存频道状态失败"
        }
    }

    private func move(from source: Int, to destination: Int) async {
        guard source != destination else { return }
        do {
            channels = try await dependencies.channelService.move(from: source, to: destination)
        } catch {
            message = "保存频道顺序失败"
        }
    }

    private func syncRemote() async {
        busy = true
        defer { busy = false }

        do {
            channels = try await dependencies.channelService.syncRemoteChannels()
            message = "已同步远端频道（共 \(channels.count) 个）"
        } catch let error as XmlyError {
            message = error.message
        } catch {
            message = "同步远端频道失败"
        }
    }
}
