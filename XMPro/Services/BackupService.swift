import Foundation

struct BackupImportResult: Sendable {
    let accounts: Int
    let subscriptions: Int
}

struct BackupImportError: Error, CustomStringConvertible,
                          CustomDebugStringConvertible {
    let result: BackupImportResult
    let error: XmlyError

    var description: String {
        "BackupImportError(savedAccounts: \(result.accounts))"
    }

    var debugDescription: String { description }
}

struct BackupService {
    private struct Entry {
        let identity: String
        let credentials: Credentials
    }

    private struct ValidatedBackup {
        let state: StateDocument
        let entries: [Entry]
    }

    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    func export(
        state: [String: Any],
        includeCredentials: Bool,
        vault: CredentialsVault
    ) async throws -> Data {
        let document: StateDocument
        do {
            document = try StateDocument(json: state)
        } catch {
            throw s4Error(error, fallback: "备份资料格式无效")
        }

        var payload: [String: Any] = [
            "app": "XMPro",
            "version": 1,
            "exportedAt": Int64(now().timeIntervalSince1970 * 1_000),
            "state": document.json
        ]

        if includeCredentials {
            var entries: [[String: Any]] = []
            for identity in try await vault.identities() {
                guard let credentials = try? await vault.load(identity: identity) else {
                    continue
                }
                entries.append([
                    "identity": identity,
                    "token": credentials.token,
                    "deviceId": credentials.deviceId
                ])
            }
            payload["accounts"] = entries
        }

        do {
            return try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw XmlyError.failure(
                code: .invalidJSON, message: "无法生成备份数据", definitive: true
            )
        }
    }

    // UI 协调层可先校验，再停止播放；损坏输入不会触发播放状态写入。
    func validate(data: Data) throws {
        _ = try validated(data: data)
    }

    func `import`(
        data: Data,
        repository: StateRepository,
        vault: CredentialsVault
    ) async throws -> BackupImportResult {
        let backup = try validated(data: data)
        var replacement = backup.state

        // 按 Kotlin 顺序，在保存导入凭据之前依据当前 vault 校准活动身份。
        if let active = replacement.activeAccountId {
            let credentials = try await vault.load(identity: active)
            if active.isEmpty || credentials == nil {
                try replacement.setActiveAccountId(nil)
            }
        }
        let candidate = replacement

        // 赋值替换整棵树，旧扩展键也不会残留；仍由 transaction 校验、落盘。
        try await repository.transaction { document in
            document = candidate
        }

        var saved = 0
        let subscriptions = backup.state.library.count
        for entry in backup.entries {
            // 与 Kotlin 一致，显式 identity 不改变 Credentials 派生的存储身份。
            _ = entry.identity
            do {
                try await vault.save(entry.credentials)
                saved += 1
            } catch {
                throw BackupImportError(
                    result: BackupImportResult(
                        accounts: saved, subscriptions: subscriptions
                    ),
                    error: .failure(
                        code: .invalidCredentials,
                        message: "资料已恢复，已保存 \(saved) 个账号；其余登录信息保存失败，请重新导入"
                    )
                )
            }
        }

        return BackupImportResult(
            accounts: saved, subscriptions: subscriptions
        )
    }

    private func validated(data: Data) throws -> ValidatedBackup {
        let payload: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw invalid("备份文件不是有效的 JSON")
            }
            payload = object
        } catch {
            throw invalid("备份文件不是有效的 JSON")
        }

        guard payload["app"] as? String == "XMPro" else {
            throw invalid("不是 XMPro 的备份文件")
        }
        guard let state = payload["state"] as? [String: Any] else {
            throw invalid("备份缺少资料数据")
        }
        guard xmlyOptInt(state["schemaVersion"]) == 1 else {
            throw invalid("备份版本不受支持")
        }

        var entries: [Entry] = []
        for value in payload["accounts"] as? [Any] ?? [] {
            guard let item = value as? [String: Any],
                  let token = item["token"] as? String, !token.isEmpty,
                  let device = item["deviceId"] as? String, !device.isEmpty,
                  let credentials = try? Credentials.parse([
                    "token": token, "deviceId": device
                  ]) else {
                continue
            }
            let supplied = item["identity"] as? String ?? ""
            entries.append(Entry(
                identity: supplied.isEmpty ? credentials.identity : supplied,
                credentials: credentials
            ))
        }

        let document: StateDocument
        do {
            document = try StateDocument(json: state)
        } catch {
            throw invalid("备份资料格式无效")
        }
        return ValidatedBackup(state: document, entries: entries)
    }

    private func invalid(_ message: String) -> XmlyError {
        .failure(code: .invalidJSON, message: message, definitive: true)
    }
}

// 不使用 localizedDescription，避免把底层响应、文件路径或凭据带进 UI。
func s4Error(
    _ error: Error,
    fallback: String = "操作失败，请重试"
) -> XmlyError {
    if let error = error as? BackupImportError { return error.error }
    if let error = error as? XmlyError { return error }
    return .failure(code: .uncertain, message: fallback)
}
