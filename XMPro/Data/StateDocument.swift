
import Foundation

// Any 仅承载 JSONSerialization 生成的 JSON 值。
// 所有输入、输出均通过序列化隔离引用；内部树不直接暴露。
struct StateDocument: @unchecked Sendable {
    static let secretKeys: Set<String> = [
        "token", "device_id", "deviceId", "cookie", "cookie2",
        "x-tk", "headers", "password", "verificationCode"
    ]

    private var tree: [String: Any]

    init() {
        tree = [
            "schemaVersion": 1,
            "activeAccountId": NSNull(),
            "primaryAccountId": NSNull(),
            "settings": [String: Any](),
            "accounts": [String: Any](),
            "downloads": [Any](),
            "library": [String: Any](),
            "officialProgress": [String: Any](),
            "queue": [String: Any]()
        ]
    }

    init(json: [String: Any]) throws {
        try Self.inspect(json)
        tree = try Self.detached(json) as! [String: Any]
        try validate()
    }

    init(data: Data) throws {
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw StateError.corrupt
            }
            try self.init(json: object)
        } catch let error as StateError {
            throw error
        } catch {
            throw StateError.corrupt
        }
    }

    var schemaVersion: Int {
        (tree["schemaVersion"] as? NSNumber)?.intValue ?? 0
    }

    var activeAccountId: String? { tree["activeAccountId"] as? String }
    var primaryAccountId: String? { tree["primaryAccountId"] as? String }
    var settings: [String: Any] { object("settings") }
    var accounts: [String: Any] { object("accounts") }
    var downloads: [Any] { value(forKey: "downloads") as? [Any] ?? [] }
    var library: [String: Any] { object("library") }
    var history: [String: Any]? { value(forKey: "history") as? [String: Any] }
    var officialProgress: [String: Any]? {
        value(forKey: "officialProgress") as? [String: Any]
    }
    var queue: [String: Any] { object("queue") }

    var json: [String: Any] {
        // tree 始终由合法 JSON 构成，此处不存在可失败的外部输入。
        try! Self.detached(tree) as! [String: Any]
    }

    func value(forKey key: String) -> Any? {
        guard let value = tree[key] else { return nil }
        return try! Self.detached(value)
    }

    // nil 删除键；显式 JSON null 使用 NSNull()。
    // 已知键与未知键共用此入口，避免重建整棵状态树时丢失扩展字段。
    mutating func setValue(_ value: Any?, forKey key: String) throws {
        guard let value else {
            tree.removeValue(forKey: key)
            return
        }
        try Self.inspect([key: value])
        tree[key] = try Self.detached(value)
    }

    mutating func setSettings(_ value: [String: Any]) throws {
        try setValue(value, forKey: "settings")
    }

    mutating func setAccounts(_ value: [String: Any]) throws {
        try setValue(value, forKey: "accounts")
    }

    mutating func setActiveAccountId(_ value: String?) throws {
        try setValue(value.map { $0 as Any } ?? NSNull(), forKey: "activeAccountId")
    }

    mutating func setPrimaryAccountId(_ value: String?) throws {
        try setValue(value.map { $0 as Any } ?? NSNull(), forKey: "primaryAccountId")
    }

    func deepCopy() -> StateDocument {
        // 序列化脱离所有 Foundation 容器引用。
        try! StateDocument(data: encoded())
    }

    func encoded() throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: tree,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw StateError.corrupt
        }
    }

    func validate() throws {
        try Self.inspect(tree)

        guard let version = tree["schemaVersion"] as? NSNumber,
              !xmlyIsBoolean(version),
              version == NSNumber(value: 1) else {
            throw StateError.corrupt
        }

        for key in ["settings", "accounts", "library", "queue"] {
            guard tree[key] is [String: Any] else {
                throw StateError.corrupt
            }
        }
        guard tree["downloads"] is [Any] else {
            throw StateError.corrupt
        }
        for key in ["history", "officialProgress"] {
            if let value = tree[key], !(value is [String: Any]) {
                throw StateError.corrupt
            }
        }
        for key in ["activeAccountId", "primaryAccountId"] {
            guard let value = tree[key],
                  value is NSNull || value is String else {
                throw StateError.corrupt
            }
        }
    }

    static func inspect(_ node: Any) throws {
        // 显式栈检查全部深度，避免递归调用消耗调用栈。
        var pending: [Any] = [node]
        while let value = pending.popLast() {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    guard !secretKeys.contains(key) else {
                        throw StateError.secretInState
                    }
                    pending.append(child)
                }
            } else if let array = value as? [Any] {
                pending.append(contentsOf: array)
            } else if value is String || value is NSNull {
                continue
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else {
                    throw StateError.corrupt
                }
            } else {
                throw StateError.corrupt
            }
        }
    }

    private func object(_ key: String) -> [String: Any] {
        value(forKey: key) as? [String: Any] ?? [:]
    }

    private static func detached(_ value: Any) throws -> Any {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed]
            )
            return try JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
            )
        } catch {
            throw StateError.corrupt
        }
    }
}
