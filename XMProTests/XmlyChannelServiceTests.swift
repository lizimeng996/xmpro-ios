// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
@testable import XMPro

final class XmlyChannelServiceTests: XCTestCase {
    private func makeRepository() throws -> (StateRepository, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmpro-channels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StateRepository.open(directory: dir), dir)
    }

    func testChannelOrderAndEnabledStatePersistAcrossReloadWithoutDroppingSettings() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        try await repo.transaction { doc in
            var settings = doc.settings
            settings["quality"] = "m4a_128"
            try doc.setSettings(settings)
        }

        let client = XmlyClientService(
            http: FakeHTTPTransport { _, _ in [:] },
            accountContext: nil,
            clock: B1Fixture.clock()
        )
        let service = XmlyChannelService(client: client, repository: repo, clock: B1Fixture.clock())

        let initial = await service.loadSavedChannels()
        XCTAssertEqual(initial.count, XmlyChannelService.defaultChannels.count)

        let toggled = try await service.setEnabled(id: "22", enabled: false)
        XCTAssertEqual(toggled.first(where: { $0.id == "22" })?.enabled, false)

        let moved = try await service.move(from: 2, to: 0)
        XCTAssertEqual(moved[0].id, "4")
        XCTAssertEqual(moved[0].order, 0)
        await repo.close()

        let reopened = try StateRepository.open(directory: dir)
        let service2 = XmlyChannelService(client: client, repository: reopened, clock: B1Fixture.clock())
        let reloaded = await service2.loadSavedChannels()
        XCTAssertEqual(reloaded[0].id, "4")
        XCTAssertEqual(reloaded.first(where: { $0.id == "22" })?.enabled, false)

        let state = await reopened.state()
        XCTAssertEqual(state.settings["quality"] as? String, "m4a_128")
    }

    func testSyncRemoteChannelsPreservesLocalOrderAndEnabledAndAppendsNewChannels() async throws {
        let (repo, dir) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = B1Fixture.clock()
        let fake = FakeHTTPTransport { _, _ in
            [
                "ret": 0,
                "data": [
                    "subPages": [
                        ["id": "recommend", "title": "首页推荐"],
                        ["id": "audiobook", "title": "精品有声书"],
                        ["id": "radio", "title": "广播剧"]
                    ]
                ]
            ]
        }
        let client = XmlyClientService(http: fake, accountContext: nil, clock: clock)
        let service = XmlyChannelService(client: client, repository: repo, clock: clock)

        _ = try await service.saveChannels([
            ChannelItem(id: "audiobook", title: "旧名", enabled: false, order: 0),
            ChannelItem(id: "recommend", title: "推荐", enabled: true, order: 1)
        ])

        let merged = try await service.syncRemoteChannels()
        XCTAssertEqual(merged.map(\.id), ["audiobook", "recommend", "radio"])
        XCTAssertEqual(merged[0].title, "精品有声书")
        XCTAssertEqual(merged[0].enabled, false)
        XCTAssertEqual(merged[1].title, "首页推荐")
        XCTAssertEqual(merged[2].title, "广播剧")
        XCTAssertEqual(merged[2].enabled, true)
    }

    func testFetchModulesParsesRemoteModules() async throws {
        let clock = B1Fixture.clock()
        let fake = FakeHTTPTransport { _, _ in
            [
                "ret": 0,
                "data": [
                    "modules": [
                        ["moduleId": "m1", "title": "猜你喜欢", "moduleType": "guess", "list": [["id": 1], ["id": 2]]]
                    ]
                ]
            ]
        }
        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context(), clock: clock
        )
        let service = XmlyChannelService(client: client, repository: nil, clock: clock)
        let modules = try await service.fetchModules(channelId: "recommend")
        XCTAssertEqual(modules.count, 1)
        XCTAssertEqual(modules[0].title, "猜你喜欢")
        XCTAssertEqual(modules[0].albumCount, 2)
        XCTAssertEqual(fake.calls.last?.query["pageId"], "recommend")
        XCTAssertEqual(fake.calls.last?.authenticated, true)
    }
}
