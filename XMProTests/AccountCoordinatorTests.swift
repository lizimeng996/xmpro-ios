import Foundation
import os
import XCTest
@testable import XMPro

@MainActor
final class AccountCoordinatorTests: XCTestCase {
    func testExportCookieRoundTrip() async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount()
        let exported = try await h.coordinator().exportCookie(
            identity: credentials.identity
        )
        b1Check(exported == credentials.cookie, "s4-cookie-roundtrip")
        let parsed = try Credentials.parse(exported)
        b1Check(parsed.identity == credentials.identity, "s4-cookie-identity")
    }

    func testMissingCredentialsThrowsMissingAccount() async throws {
        let h = try S4Harness(test: self)
        let coordinator = h.coordinator()
        await b1ExpectError("missing_account", "s4-cookie-missing") {
            _ = try await coordinator.exportCookie(identity: "synthetic-missing")
        }
    }

    func testSwitchStopsBeforeAccountLookupAndClearsPlayback() async throws {
        let h = try S4Harness(test: self)
        let first = try await h.addAccount("101")
        let second = try await h.addAccount("102")
        let track = try Track(rawId: "1", duration: 120)
        let engine = S4PlayerEngine()
        let client = S4PlaybackClient(identity: first.identity, track: track)
        let session = s4Session(
            engine: engine, store: S4MemoryPlaybackStore(), client: client
        )
        await session.prepare()
        await session.play(track: track)
        XCTAssertNotNil(session.track)

        let stopped = OSAllocatedUnfairLock(initialState: false)
        engine.onStop = { stopped.withLock { $0 = true } }
        h.keys.checkStopOnLoad { stopped.withLock { $0 } }

        try await h.coordinator(session: session).switchAccount(identity: second.identity)
        XCTAssertEqual(h.keys.observedStop, true)
        XCTAssertNil(session.track)
        XCTAssertEqual(session.positionMs, 0)
        XCTAssertEqual(session.state, .idle)
        let state = await h.repository.state()
        b1Check(state.activeAccountId == second.identity, "s4-switch-active")
        b1Check(state.primaryAccountId == first.identity, "s4-switch-primary")
        let oldCredentials = try await h.vault.load(identity: first.identity)
        b1Check(oldCredentials != nil, "s4-switch-keeps-credentials")
    }

    func testRemovingActiveAccountStopsAndDeletesCredentials() async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount()
        let track = try Track(rawId: "1", duration: 120)
        let engine = S4PlayerEngine()
        let session = s4Session(
            engine: engine,
            store: S4MemoryPlaybackStore(),
            client: S4PlaybackClient(identity: credentials.identity, track: track)
        )
        await session.prepare()
        await session.play(track: track)

        let stopped = OSAllocatedUnfairLock(initialState: false)
        engine.onStop = { stopped.withLock { $0 = true } }
        h.keys.checkStopOnLoad { stopped.withLock { $0 } }

        let recovery = await h.coordinator(session: session).removeAccount(
            identity: credentials.identity
        )
        XCTAssertEqual(recovery, .none)
        XCTAssertEqual(h.keys.observedStop, true)
        XCTAssertNil(session.track)
        let stored = try await h.vault.load(identity: credentials.identity)
        let state = await h.repository.state()
        b1Check(stored == nil, "s4-remove-vault")
        b1Check(state.accounts[credentials.identity] == nil, "s4-remove-record")
    }

    func testSignOutKeepsRecordAndClearsActiveWithoutFallback() async throws {
        let h = try S4Harness(test: self)
        let first = try await h.addAccount("101")
        _ = try await h.addAccount("102")
        let coordinator = h.coordinator()
        await coordinator.signOut(identity: first.identity)
        XCTAssertNil(coordinator.lastError)

        let state = await h.repository.state()
        let credentials = try await h.vault.load(identity: first.identity)
        XCTAssertNil(state.activeAccountId)
        b1Check(state.accounts[first.identity] != nil, "s4-signout-record")
        b1Check(state.primaryAccountId == first.identity, "s4-signout-primary")
        b1Check(credentials == nil, "s4-signout-vault")

        await coordinator.signOut(identity: first.identity)
        XCTAssertNil(coordinator.lastError)
    }

    func testRemovingInactiveAccountDoesNotStopPlayback() async throws {
        let h = try S4Harness(test: self)
        let first = try await h.addAccount("101")
        let second = try await h.addAccount("102")
        let track = try Track(rawId: "1", duration: 120)
        let engine = S4PlayerEngine()
        let session = s4Session(
            engine: engine,
            store: S4MemoryPlaybackStore(),
            client: S4PlaybackClient(identity: first.identity, track: track)
        )
        await session.prepare()
        await session.play(track: track)
        var stops = 0
        engine.onStop = { stops += 1 }

        _ = await h.coordinator(session: session).removeAccount(identity: second.identity)
        XCTAssertEqual(stops, 0)
        XCTAssertEqual(session.track?.id, track.id)
        session.stop()
    }
}
