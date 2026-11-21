import XCTest
@testable import XMPro

@MainActor
final class PlaybackQueueBridgeTests: XCTestCase {
    func testBufferedDiscreteCommandsArriveInOrderWithoutLoss() async throws {
        var bridge: PlaybackQueueBridge? = PlaybackQueueBridge()
        let commands = try XCTUnwrap(bridge).commands
        let expected: [PlaybackQueueBridge.Command] = [
            .next,
            .previous,
            .toggle,
            .seek(1_234),
            .play,
            .pause,
            .next,
            .seek(9_000),
            .toggle,
            .previous,
            .seek(0),
            .next
        ]

        for command in expected {
            bridge?.request(command)
        }

        // 提交完毕后释放生产者并结束流，再读取缓冲。
        // 即使发生丢失，测试也会完成并报告数量错误，不会等待缺失命令。
        bridge = nil

        var received: [PlaybackQueueBridge.Command] = []
        for await command in commands {
            received.append(command)
        }

        XCTAssertEqual(received.count, expected.count)
        for (index, pair) in zip(received, expected).enumerated() {
            switch pair {
            case (.next, .next),
                 (.previous, .previous),
                 (.play, .play),
                 (.pause, .pause),
                 (.toggle, .toggle):
                break
            case let (.seek(actual), .seek(expectedPosition)):
                XCTAssertEqual(
                    actual, expectedPosition,
                    "第 \(index) 条 seek 命令的位置不一致"
                )
            default:
                XCTFail("第 \(index) 条命令不一致")
            }
        }
    }

    func testInitialSnapshotRepresentsEmptyQueue() {
        let bridge = PlaybackQueueBridge()
        XCTAssertEqual(bridge.snapshot.index, 0)
        XCTAssertEqual(bridge.snapshot.size, 0)
    }
}
