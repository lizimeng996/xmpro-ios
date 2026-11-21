import SwiftUI

enum LoadState {
    // 无加载、空态或错误需要展示时，显示调用方的 content。
    // 数据加载完成后使用 idle；数据本身由调用方持有。
    case idle
    case loading
    case empty(message: String)
    case error(XmlyError, retry: () -> Void)
}

struct LoadStateView<StateContent: View>: View {
    let state: LoadState
    private let content: () -> StateContent

    init(
        state: LoadState,
        @ViewBuilder content: @escaping () -> StateContent
    ) {
        self.state = state
        self.content = content
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                content()

            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在加载…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()

            case let .empty(message):
                XMEmptyState(
                    systemImage: "tray",
                    title: "暂无内容",
                    message: message
                )

            case let .error(error, retry):
                XMEmptyState(
                    systemImage: "exclamationmark.triangle",
                    title: "加载失败",
                    message: error.message
                ) {
                    Button("重试", action: retry)
                        .xmProminentButton()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
