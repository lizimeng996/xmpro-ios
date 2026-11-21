
import Foundation
import XCTest
@testable import XMPro

// 本轮仅交付代码文本；以下测试需由执行侧在 Apple 测试环境验证。
final class StateRepositoryTests: XCTestCase {
    private let androidFixture = """
    {
      "schemaVersion": 1,
      "activeAccountId": "deadbeef",
      "primaryAccountId": "deadbeef",
      "settings": {"playbackSpeed": 1.5, "skipIntroSeconds": 10},
      "accounts": {
        "deadbeef": {
          "uid": "123456",
          "deviceHint": "abcdef",
          "nickname": "测试账号",
          "quota": {
            "remainingSeconds": 3600,
            "newDevice": false,
            "checkedAt": 1700000000000
          },
          "paused": false
        }
      },
      "downloads": [],
      "library": {"pinnedAlbumIds": ["1001"]},
      "officialProgress": {},
      "queue": {},
      "futureUnknownTopLevel": {"someNewField": [1, 2, 3]},
      "history": {}
    }
    """

    func testDefaultStateShape() async throws {
        let (_, repository) = try makeRepository()
        let document = await repository.state()
        let expectedKeys: Set<String> = [
            "schemaVersion", "activeAccountId", "primaryAccountId",
            "settings", "accounts", "downloads", "library",
            "officialProgress", "queue"
        ]
        XCTAssertTrue(Set(document.json.keys) == expectedKeys, "default_keys")
        XCTAssertEqual(document.schemaVersion, 1, "default_schema")
        XCTAssertTrue(document.value(forKey: "activeAccountId") is NSNull, "default_active")
        XCTAssertTrue(document.value(forKey: "primaryAccountId") is NSNull, "default_primary")
        XCTAssertTrue(document.settings.isEmpty, "default_settings")
        XCTAssertTrue(document.accounts.isEmpty, "default_accounts")
        XCTAssertTrue(document.downloads.isEmpty, "default_downloads")
        XCTAssertTrue(document.library.isEmpty, "default_library")
        XCTAssertTrue(document.officialProgress?.isEmpty == true, "default_progress")
        XCTAssertTrue(document.queue.isEmpty, "default_queue")
        XCTAssertNil(document.history, "default_history")
    }

    func testAndroidFixtureRoundTripPreservesUnknownFields() async throws {
        let directory = try makeDirectory()
        let original = try StateDocument(data: Data(androidFixture.utf8))
        try Data(androidFixture.utf8).write(
            to: directory.appendingPathComponent("state.json")
        )

        let repository = try StateRepository.open(directory: directory)
        addTeardownBlock { await repository.close() }
        try await repository.transaction { document in
            var settings = document.settings
            settings["playbackSpeed"] = 2.0
            try document.setSettings(settings)
        }
        await repository.close()

        let reopened = try StateRepository.open(directory: directory)
        addTeardownBlock { await reopened.close() }
        let actual = await reopened.state()

        XCTAssertTrue(
            semanticEqual(
                original.value(forKey: "futureUnknownTopLevel"),
                actual.value(forKey: "futureUnknownTopLevel")
            ),
            "android_unknown_top"
        )
        XCTAssertTrue(
            semanticEqual(original.library, actual.library),
            "android_unknown_library"
        )
        XCTAssertTrue(
            semanticEqual(original.accounts, actual.accounts),
            "android_account_quota"
        )
        XCTAssertEqual(actual.settings["playbackSpeed"] as? Double, 2, "android_speed")
        XCTAssertEqual(actual.settings["skipIntroSeconds"] as? Int, 10, "android_skip")
    }

    func testEverySecretKeyIsRejectedAtNestedDepth() async throws {
        let (directory, repository) = try makeRepository()
        try await repository.transaction { _ in }
        let stateURL = directory.appendingPathComponent("state.json")
        let original = try Data(contentsOf: stateURL)

        for key in StateDocument.secretKeys.sorted() {
            await expectStateError("secret_in_state", caseID: "secret_nested") {
                try await repository.transaction { document in
                    try document.setValue(
                        ["nested": [["deeper": [key: "fixture"]]]],
                        forKey: "future"
                    )
                }
            }
            let current = await repository.state()
            XCTAssertNil(current.value(forKey: "future"), "secret_memory")
            XCTAssertTrue(try Data(contentsOf: stateURL) == original, "secret_disk")
        }
    }

    func testCorruptJSONReportsCorrupt() throws {
        let directory = try makeDirectory()
        try Data("{broken".utf8).write(
            to: directory.appendingPathComponent("state.json")
        )
        expectOpenError(directory, code: "corrupt", caseID: "corrupt_json")
    }

    func testInvalidShapeReportsCorrupt() throws {
        let directory = try makeDirectory()
        var object = StateDocument().json
        object["settings"] = []
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: directory.appendingPathComponent("state.json"))
        expectOpenError(directory, code: "corrupt", caseID: "corrupt_shape")
    }

    func testOversizedTransactionPreservesOldState() async throws {
        let (directory, repository) = try makeRepository()
        try await repository.transaction { _ in }
        let stateURL = directory.appendingPathComponent("state.json")
        let oldData = try Data(contentsOf: stateURL)

        await expectStateError("too_large", caseID: "write_limit") {
            try await repository.transaction { document in
                try document.setValue(
                    String(repeating: "x", count: StateRepository.maxStateBytes),
                    forKey: "oversized"
                )
            }
        }
        let current = await repository.state()
        XCTAssertNil(current.value(forKey: "oversized"), "write_limit_memory")
        XCTAssertTrue(try Data(contentsOf: stateURL) == oldData, "write_limit_disk")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") }, "write_limit_temporary")
    }

    func testOversizedExistingFileReportsCorrupt() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("state.json")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: url.path, contents: Data()),
            "read_limit_create"
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(StateRepository.maxStateBytes + 1))
        try handle.close()
        expectOpenError(directory, code: "corrupt", caseID: "read_limit")
    }

    func testBackupWithoutStateRequiresRecovery() throws {
        let directory = try makeDirectory()
        try Data(androidFixture.utf8).write(
            to: directory.appendingPathComponent("state.backup")
        )
        expectOpenError(
            directory, code: "recovery_required", caseID: "backup_recovery"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("state.json").path
            ),
            "backup_no_automatic_restore"
        )
    }

    func testDuplicateCanonicalDirectoryIsLocked() async throws {
        let (directory, repository) = try makeRepository()
        let alias = directory.appendingPathComponent(".", isDirectory: true)
        expectOpenError(alias, code: "locked", caseID: "duplicate_open")

        await repository.close()
        let reopened = try StateRepository.open(directory: alias)
        await reopened.close()
    }

    func testTransactionAfterCloseReportsClosed() async throws {
        let (_, repository) = try makeRepository()
        await repository.close()
        await expectStateError("closed", caseID: "closed_transaction") {
            try await repository.transaction { _ in }
        }
    }

    func testConcurrentTransactionsDoNotLoseUpdates() async throws {
        let (_, repository) = try makeRepository()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await repository.transaction { document in
                        var settings = document.settings
                        settings["counter"] = (settings["counter"] as? Int ?? 0) + 1
                        try document.setSettings(settings)
                    }
                }
            }
            try await group.waitForAll()
        }
        let document = await repository.state()
        XCTAssertEqual(document.settings["counter"] as? Int, 20, "concurrent_counter")
    }

    func testSnapshotsAndInputReferencesAreDetached() async throws {
        let (_, repository) = try makeRepository()
        let external = NSMutableDictionary(dictionary: ["value": 1])
        var local = StateDocument()
        try local.setValue(external, forKey: "future")
        external["value"] = 2
        XCTAssertEqual(
            (local.value(forKey: "future") as? [String: Any])?["value"] as? Int,
            1,
            "detached_input"
        )

        var snapshot = await repository.state()
        try snapshot.setSettings(["changed": true])
        let unchanged = await repository.state()
        XCTAssertTrue(unchanged.settings.isEmpty, "detached_snapshot")
    }

    func testNonFiniteValuesAreRejected() async throws {
        let (_, repository) = try makeRepository()
        await expectStateError("corrupt", caseID: "nonfinite_double") {
            try await repository.transaction {
                try $0.setValue(["nested": Double.infinity], forKey: "future")
            }
        }
        await expectStateError("corrupt", caseID: "nonfinite_float") {
            try await repository.transaction {
                try $0.setValue(["nested": Float.nan], forKey: "future")
            }
        }
    }

    func testOpenRemovesTransientDirectories() async throws {
        let directory = try makeDirectory()
        for child in ["captcha", "playback-cache"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(child),
                withIntermediateDirectories: true
            )
        }
        let repository = try StateRepository.open(directory: directory)
        await repository.close()
        for child in ["captcha", "playback-cache"] {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(child).path
                ),
                "transient_removed"
            )
        }
    }

    func testRelativeDirectoryIsRejected() throws {
        do {
            _ = try StateRepository.open(directory: "relative-fixture")
            XCTFail("relative_directory")
        } catch let error as StateError {
            XCTAssertEqual(error.code, "directory", "relative_directory")
        } catch {
            XCTFail("relative_directory_type")
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func makeRepository() throws -> (URL, StateRepository) {
        let directory = try makeDirectory()
        let repository = try StateRepository.open(directory: directory)
        addTeardownBlock { await repository.close() }
        return (directory, repository)
    }

    private func expectOpenError(
        _ directory: URL,
        code: String,
        caseID: String
    ) {
        do {
            _ = try StateRepository.open(directory: directory)
            XCTFail(caseID)
        } catch let error as StateError {
            XCTAssertEqual(error.code, code, caseID)
        } catch {
            XCTFail(caseID)
        }
    }

    private func expectStateError(
        _ code: String,
        caseID: String,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail(caseID)
        } catch let error as StateError {
            XCTAssertEqual(error.code, code, caseID)
        } catch {
            XCTFail(caseID)
        }
    }

    private func semanticEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs,
              let left = try? JSONSerialization.data(
                withJSONObject: lhs, options: [.sortedKeys, .fragmentsAllowed]
              ),
              let right = try? JSONSerialization.data(
                withJSONObject: rhs, options: [.sortedKeys, .fragmentsAllowed]
              ) else {
            return false
        }
        return left == right
    }
}
