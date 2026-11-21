import Combine
import Foundation

@MainActor
final class CommentsSession: ObservableObject {
    typealias ClientFactory = @MainActor () async throws -> XmlyClientService

    private(set) var client: XmlyClientService
    private(set) var trackNumber: String?
    private let clientFactory: ClientFactory?
    private var generation: UInt64 = 0

    @Published private(set) var comments: [Comment] = []
    @Published private(set) var page = 0
    @Published private(set) var total = 0
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    @Published private(set) var error: XmlyError?

    init(
        client: XmlyClientService,
        clientFactory: ClientFactory? = nil
    ) {
        self.client = client
        self.clientFactory = clientFactory
    }

    func open(trackNumber: String) async {
        reset()
        self.trackNumber = trackNumber
        await load(page: 1, refreshClient: true)
    }

    func loadMore() async {
        guard !loading, hasMore, trackNumber != nil else { return }
        await load(page: page + 1, refreshClient: false)
    }

    func retry() async {
        guard !loading, trackNumber != nil else { return }
        await load(page: 1, refreshClient: true)
    }

    func reset() {
        generation &+= 1
        trackNumber = nil
        comments = []
        page = 0
        total = 0
        hasMore = false
        loading = false
        error = nil
    }

    private func load(page requestedPage: Int, refreshClient: Bool) async {
        guard let number = trackNumber else { return }
        let requestGeneration = generation
        loading = true
        error = nil

        do {
            let boundClient: XmlyClientService
            if refreshClient, let clientFactory {
                boundClient = try await clientFactory()
            } else {
                boundClient = client
            }
            guard generation == requestGeneration else { return }
            client = boundClient
            let result = try await boundClient.trackComments(
                number: number, page: requestedPage
            )
            guard generation == requestGeneration else { return }
            comments = requestedPage <= 1
                ? result.comments : comments + result.comments
            page = result.page
            total = result.total
            hasMore = result.hasMore
            loading = false
            error = nil
        } catch {
            guard generation == requestGeneration else { return }
            loading = false
            self.error = s4Error(error, fallback: "评论加载失败，请重试")
        }
    }
}
