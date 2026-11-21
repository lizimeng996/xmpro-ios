import Foundation
import XCTest
@testable import XMPro

@MainActor
final class CommentsSessionTests: XCTestCase {
    private func response(page: Int, pages: Int = 2) -> [String: Any] {
        [
            "data": [
                "currentPage": page, "totalPage": pages, "totalComment": pages,
                "comments": [[
                    "id": String(page),
                    "uid": "101",
                    "nickname": "合成听友",
                    "content": "评论 \(page)",
                    "createAt": "合成时间",
                    "likes": 2,
                    "replyCount": 0
                ]]
            ]
        ]
    }

    private func session(_ transport: FakeHTTPTransport) -> CommentsSession {
        CommentsSession(client: XmlyClientService(
            http: transport, accountContext: nil, clock: B1Fixture.clock()
        ))
    }

    func testOpenLoadsFirstPageAndResetsPreviousTrack() async {
        let first = response(page: 1)
        let transport = FakeHTTPTransport { call, _ in
            b1Check(call.query["page"] == "1", "s4-comments-first")
            b1Check(!call.authenticated, "s4-comments-anonymous")
            return first
        }
        let subject = session(transport)
        await subject.open(trackNumber: "1")
        await subject.open(trackNumber: "2")
        XCTAssertEqual(subject.trackNumber, "2")
        XCTAssertEqual(subject.page, 1)
        XCTAssertEqual(subject.comments.count, 1)
        XCTAssertFalse(subject.loading)
        XCTAssertNil(subject.error)
    }

    func testLoadMoreAppends() async {
        let first = response(page: 1)
        let second = response(page: 2)
        let transport = FakeHTTPTransport { call, _ in
            call.query["page"] == "1" ? first : second
        }
        let subject = session(transport)
        await subject.open(trackNumber: "1")
        await subject.loadMore()
        XCTAssertEqual(subject.comments.map(\.id), ["1", "2"])
        XCTAssertEqual(subject.page, 2)
        XCTAssertFalse(subject.hasMore)
    }

    func testNoMoreDoesNotRequest() async {
        let only = response(page: 1, pages: 1)
        let transport = FakeHTTPTransport { _, _ in only }
        let subject = session(transport)
        await subject.open(trackNumber: "1")
        await subject.loadMore()
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testFailureKeepsOldList() async {
        let first = response(page: 1)
        let transport = FakeHTTPTransport { _, count in
            if count == 1 { return first }
            throw XmlyError.failure(code: .network, message: "合成网络错误")
        }
        let subject = session(transport)
        await subject.open(trackNumber: "1")
        await subject.loadMore()
        XCTAssertEqual(subject.comments.map(\.id), ["1"])
        XCTAssertEqual(subject.page, 1)
        XCTAssertTrue(subject.hasMore)
        XCTAssertFalse(subject.loading)
        XCTAssertEqual(subject.error?.code, "network")
    }

    func testRetryReplacesWithFirstPage() async {
        let first = response(page: 1)
        let second = response(page: 2)
        let transport = FakeHTTPTransport { call, _ in
            call.query["page"] == "1" ? first : second
        }
        let subject = session(transport)
        await subject.open(trackNumber: "1")
        await subject.loadMore()
        await subject.retry()
        XCTAssertEqual(subject.page, 1)
        XCTAssertEqual(subject.comments.map(\.id), ["1"])
        XCTAssertTrue(subject.hasMore)
        XCTAssertNil(subject.error)
        XCTAssertEqual(transport.calls.last?.query["page"], "1")
    }
}
