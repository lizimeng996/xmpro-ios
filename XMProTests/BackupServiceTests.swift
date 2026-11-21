import Foundation
import XCTest
@testable import XMPro

@MainActor
final class BackupServiceTests: XCTestCase {
    private let service = BackupService()

    private func data(_ payload: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func payload(
        state: StateDocument = StateDocument(),
        credentials: [Credentials] = []
    ) -> [String: Any] {
        [
            "app": "XMPro",
            "version": 1,
            "state": state.json,
            "accounts": credentials.map {
                [
                    "identity": $0.identity,
                    "token": $0.token,
                    "deviceId": $0.deviceId
                ]
            }
        ]
    }

    private func assertRejectedWithoutMutation(
        _ input: Data,
        expectedCode: String,
        expectedMessage: String,
        caseID: String
    ) async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount()
        try await h.repository.transaction {
            try $0.setValue("retained", forKey: "extension")
        }
        let before = try await h.repository.state().encoded()
        do {
            _ = try await service.import(
                data: input, repository: h.repository, vault: h.vault
            )
            XCTFail(caseID)
        } catch let error as XmlyError {
            b1Check(error.code == expectedCode, caseID + "-code")
            b1Check(error.message == expectedMessage, caseID + "-message")
            b1Check(error.definitive, caseID + "-definitive")
        } catch {
            XCTFail(caseID + "-type")
        }
        let after = try await h.repository.state().encoded()
        let stored = try await h.vault.load(identity: credentials.identity)
        b1Check(before == after, caseID + "-state")
        b1Check(stored?.cookie == credentials.cookie, caseID + "-vault")
    }

    func testExportWithoutCredentialsOmitsAccounts() async throws {
        let h = try S4Harness(test: self)
        _ = try await h.addAccount()
        let state = await h.repository.state()
        let exported = try await service.export(
            state: state.json, includeCredentials: false, vault: h.vault
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        XCTAssertNil(object["accounts"])
        XCTAssertEqual(object["app"] as? String, "XMPro")
        let restored = try StateDocument(
            json: XCTUnwrap(object["state"] as? [String: Any])
        )
        b1Check(try restored.encoded() == state.encoded(), "s4-backup-public")
    }

    func testExportWithCredentialsKeepsTokensOutOfState() async throws {
        let h = try S4Harness(test: self)
        let credentials = try await h.addAccount()
        let state = await h.repository.state()
        let exported = try await service.export(
            state: state.json, includeCredentials: true, vault: h.vault
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: exported) as? [String: Any]
        )
        let entries = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        b1Check(entries.count == 1, "s4-backup-entries")
        let parsed = try Credentials.parse(entries[0])
        b1Check(parsed.cookie == credentials.cookie, "s4-backup-credential-roundtrip")
        let restored = try StateDocument(
            json: XCTUnwrap(object["state"] as? [String: Any])
        )
        b1Check(try restored.encoded() == state.encoded(), "s4-backup-state-clean")
    }

    func testImportReturnsCredentialAndLibraryCounts() async throws {
        let h = try S4Harness(test: self)
        let credential = try Credentials(
            token: "201&synthetic_restore", deviceId: "synthetic-restore-device"
        )
        var state = StateDocument()
        try state.setAccounts([credential.identity: ["uid": credential.uid]])
        try state.setValue(["first": [:], "second": [:]], forKey: "library")
        let result = try await service.import(
            data: data(payload(state: state, credentials: [credential])),
            repository: h.repository,
            vault: h.vault
        )
        XCTAssertEqual(result.accounts, 1)
        XCTAssertEqual(result.subscriptions, 2)
        let restored = try await h.vault.load(identity: credential.identity)
        b1Check(restored?.cookie == credential.cookie, "s4-backup-restored")
    }

    func testInvalidJSONDoesNotMutate() async throws {
        try await assertRejectedWithoutMutation(
            Data("{broken".utf8),
            expectedCode: "invalid_json",
            expectedMessage: "备份文件不是有效的 JSON",
            caseID: "s4-backup-json"
        )
    }

    func testWrongAppDoesNotMutate() async throws {
        var object = payload()
        object["app"] = "Other"
        try await assertRejectedWithoutMutation(
            data(object),
            expectedCode: "invalid_json",
            expectedMessage: "不是 XMPro 的备份文件",
            caseID: "s4-backup-app"
        )
    }

    func testMissingStateDoesNotMutate() async throws {
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro"]),
            expectedCode: "invalid_json",
            expectedMessage: "备份缺少资料数据",
            caseID: "s4-backup-missing-state"
        )
    }

    func testWrongVersionDoesNotMutate() async throws {
        var state = StateDocument().json
        state["schemaVersion"] = 2
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份版本不受支持",
            caseID: "s4-backup-version"
        )
    }

    func testStringVersionPassesPrecheckButStateDocumentRejects() async throws {
        var state = StateDocument().json
        state["schemaVersion"] = "1"
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份资料格式无效",
            caseID: "s4-backup-string-version"
        )
    }

    func testFractionalVersionPassesPrecheckButStateDocumentRejects() async throws {
        var state = StateDocument().json
        state["schemaVersion"] = 1.5
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份资料格式无效",
            caseID: "s4-backup-fractional-version"
        )
    }

    func testBooleanVersionIsRejectedByPrecheck() async throws {
        var state = StateDocument().json
        state["schemaVersion"] = true
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份版本不受支持",
            caseID: "s4-backup-boolean-version"
        )
    }

    func testWrappingIntegerVersionPassesPrecheckButStateDocumentRejects() async throws {
        // JVM optInt 取低 32 位：4294967297（2^32+1）截断为 1，通过预检；
        // StateDocument 仍要求 NSNumber == 1，故以“备份资料格式无效”拒绝。
        var state = StateDocument().json
        state["schemaVersion"] = 4_294_967_297
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份资料格式无效",
            caseID: "s4-backup-wrapping-version"
        )
    }

    func testWrappingStringVersionIsRejectedByPrecheck() async throws {
        // 字符串分支先按 Int32 解析（越界失败），再按 Double 饱和截断为
        // 2147483647，不等于 1，预检即拒。
        var state = StateDocument().json
        state["schemaVersion"] = "4294967297"
        try await assertRejectedWithoutMutation(
            data(["app": "XMPro", "state": state]),
            expectedCode: "invalid_json",
            expectedMessage: "备份版本不受支持",
            caseID: "s4-backup-wrapping-string-version"
        )
    }

    func testBadCredentialEntriesAreSkipped() async throws {
        let h = try S4Harness(test: self)
        let credential = try Credentials(
            token: "201&synthetic_valid", deviceId: "synthetic-valid-device"
        )
        var object = payload()
        object["accounts"] = [
            9,
            ["token": "", "deviceId": "synthetic"],
            ["token": "bad", "deviceId": "synthetic"],
            ["token": credential.token, "deviceId": credential.deviceId, "identity": ""]
        ] as [Any]
        let result = try await service.import(
            data: data(object), repository: h.repository, vault: h.vault
        )
        XCTAssertEqual(result.accounts, 1)
        let restored = try await h.vault.load(identity: credential.identity)
        b1Check(restored != nil, "s4-backup-skip-invalid")
    }

    func testActiveAccountWithoutPreexistingCredentialsIsCleared() async throws {
        let h = try S4Harness(test: self)
        let credential = try Credentials(
            token: "201&synthetic_active", deviceId: "synthetic-active-device"
        )
        var state = StateDocument()
        try state.setAccounts([credential.identity: ["uid": credential.uid]])
        try state.setActiveAccountId(credential.identity)
        try state.setPrimaryAccountId(credential.identity)
        _ = try await service.import(
            data: data(payload(state: state, credentials: [credential])),
            repository: h.repository,
            vault: h.vault
        )
        let restored = await h.repository.state()
        XCTAssertNil(restored.activeAccountId)
        b1Check(restored.primaryAccountId == credential.identity, "s4-backup-primary")
        let saved = try await h.vault.load(identity: credential.identity)
        b1Check(saved != nil, "s4-backup-active-saved-after-calibration")
    }

    func testReplacementRemovesOldKeysAndKeepsBackupExtensions() async throws {
        let h = try S4Harness(test: self)
        try await h.repository.transaction {
            try $0.setValue("old", forKey: "oldExtension")
        }
        var replacement = StateDocument()
        try replacement.setValue("new", forKey: "newExtension")
        _ = try await service.import(
            data: data(payload(state: replacement)),
            repository: h.repository,
            vault: h.vault
        )
        let restored = await h.repository.state()
        XCTAssertNil(restored.value(forKey: "oldExtension"))
        XCTAssertEqual(restored.value(forKey: "newExtension") as? String, "new")
    }

    func testVaultFailureReportsPartialCountWithoutRollingBackState() async throws {
        let h = try S4Harness(test: self)
        let first = try Credentials(
            token: "201&synthetic_first", deviceId: "synthetic-first-device"
        )
        let second = try Credentials(
            token: "202&synthetic_second", deviceId: "synthetic-second-device"
        )
        var replacement = StateDocument()
        try replacement.setValue("restored", forKey: "marker")
        h.keys.failAfterSuccessfulSaves(1)

        do {
            _ = try await service.import(
                data: data(payload(state: replacement, credentials: [first, second])),
                repository: h.repository,
                vault: h.vault
            )
            XCTFail("s4-backup-partial")
        } catch let error as BackupImportError {
            XCTAssertEqual(error.result.accounts, 1)
            XCTAssertTrue(error.error.message.contains("已保存 1 个账号"))
        }
        let state = await h.repository.state()
        XCTAssertEqual(state.value(forKey: "marker") as? String, "restored")
        let firstSaved = try await h.vault.load(identity: first.identity)
        let secondSaved = try await h.vault.load(identity: second.identity)
        b1Check(firstSaved != nil && secondSaved == nil, "s4-backup-partial-vault")
    }
}
