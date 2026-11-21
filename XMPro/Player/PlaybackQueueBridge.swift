import Combine
import Foundation

@MainActor
final class PlaybackQueueBridge: ObservableObject {
    enum Command: Sendable {
        case next
        case previous
        case play
        case pause
        case toggle
        case seek(Int64)
    }

    typealias Snapshot = PlaybackQueue.Snapshot

    let commands: AsyncStream<Command>
    @Published private(set) var snapshot = Snapshot(index: 0, size: 0)
    private let continuation: AsyncStream<Command>.Continuation

    init() {
        var captured: AsyncStream<Command>.Continuation!
        commands = AsyncStream(bufferingPolicy: .unbounded) {
            captured = $0
        }
        continuation = captured
    }

    func publish(snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    // 离散控制命令由用户操作驱动，消费者顺序处理，使用无界缓冲避免丢弃。
    // 与 Kotlin 有意不同：MutableSharedFlow(extraBufferCapacity = 8)
    // 配合 tryEmit 在缓冲满时也会丢弃命令；iOS 刻意采用更严格的不丢弃语义。
    func request(_ command: Command) {
        continuation.yield(command)
    }

    deinit {
        continuation.finish()
    }
}
