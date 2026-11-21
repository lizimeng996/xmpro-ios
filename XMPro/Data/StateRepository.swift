
import Foundation

// 存储层采用任务明确允许的独立错误枚举，不扩展 S1 协议错误码。
enum StateError: String, Error, LocalizedError, Sendable {
    case closed
    case tooLarge = "too_large"
    case writeFailed = "write_failed"
    case directory
    case locked
    case corrupt
    case recoveryRequired = "recovery_required"
    case secretInState = "secret_in_state"

    var code: String { rawValue }

    var message: String {
        switch self {
        case .closed: return "状态仓库已关闭"
        case .tooLarge: return "状态文件超过大小上限"
        case .writeFailed: return "状态文件写入失败"
        case .directory: return "状态目录不可用"
        case .locked: return "状态目录已打开"
        case .corrupt: return "状态文件损坏"
        case .recoveryRequired: return "状态文件需要显式恢复"
        case .secretInState: return "状态中禁止保存敏感字段"
        }
    }

    var errorDescription: String? { "\(code)：\(message)" }
}

private final class StateDirectoryRegistry: @unchecked Sendable {
    static let shared = StateDirectoryRegistry()

    private let lock = NSLock()
    private var paths: Set<String> = []

    func acquire(_ path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard paths.insert(path).inserted else {
            throw StateError.locked
        }
    }

    func release(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.remove(path)
    }
}

private final class StateDirectoryLease: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var released = false

    init(path: String) throws {
        self.path = path
        try StateDirectoryRegistry.shared.acquire(path)
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return }
        released = true
        StateDirectoryRegistry.shared.release(path)
    }

    deinit {
        release()
    }
}

actor StateRepository {
    static let maxStateBytes = 64 * 1024 * 1024

    private let directory: URL
    private let lease: StateDirectoryLease
    private var document: StateDocument
    private var isClosed = false

    private init(
        directory: URL,
        lease: StateDirectoryLease,
        document: StateDocument
    ) {
        self.directory = directory
        self.lease = lease
        self.document = document
    }

    static func open(directory: String) throws -> StateRepository {
        guard (directory as NSString).isAbsolutePath else {
            throw StateError.directory
        }

        let manager = FileManager.default
        let requested = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try manager.createDirectory(
                at: requested, withIntermediateDirectories: true
            )
        } catch {
            throw StateError.directory
        }

        let canonical = requested.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard manager.fileExists(
            atPath: canonical.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw StateError.directory
        }

        let lease = try StateDirectoryLease(path: canonical.path)
        do {
            // iOS 单实例使用进程内独占租约；保留 Android 的锁文件布局。
            let lockURL = canonical.appendingPathComponent("state.lock")
            if !manager.fileExists(atPath: lockURL.path) {
                guard manager.createFile(atPath: lockURL.path, contents: Data()) else {
                    throw StateError.locked
                }
            }
            do {
                let handle = try FileHandle(forWritingTo: lockURL)
                try handle.close()
            } catch {
                throw StateError.locked
            }

            let stateURL = canonical.appendingPathComponent("state.json")
            let backupURL = canonical.appendingPathComponent("state.backup")
            let document: StateDocument
            if manager.fileExists(atPath: stateURL.path) {
                do {
                    let data = try readBounded(stateURL)
                    document = try StateDocument(data: data)
                } catch {
                    // 打开已有状态时，过大、敏感字段、校验失败均归为损坏。
                    throw StateError.corrupt
                }
            } else if manager.fileExists(atPath: backupURL.path) {
                throw StateError.recoveryRequired
            } else {
                document = StateDocument()
            }

            for child in ["captcha", "playback-cache"] {
                let url = canonical.appendingPathComponent(child)
                if manager.fileExists(atPath: url.path) {
                    // 与 Kotlin sweepSessionDirectories 一致：清扫失败不阻断打开。
                    try? manager.removeItem(at: url)
                }
            }

            return StateRepository(
                directory: canonical, lease: lease, document: document
            )
        } catch {
            lease.release()
            throw error
        }
    }

    static func open(directory: URL) throws -> StateRepository {
        guard directory.isFileURL else { throw StateError.directory }
        return try open(directory: directory.path)
    }

    func state() -> StateDocument {
        document.deepCopy()
    }

    // 更新闭包不允许挂起，整个事务始终占有 actor 的执行权。
    func transaction(
        _ update: @Sendable (inout StateDocument) throws -> Void
    ) throws {
        guard !isClosed else { throw StateError.closed }
        var candidate = document.deepCopy()
        try update(&candidate)
        try candidate.validate()

        let data = try candidate.encoded()
        guard data.count <= Self.maxStateBytes else {
            throw StateError.tooLarge
        }

        let temporary = directory.appendingPathComponent(
            "state.\(UUID().uuidString.lowercased()).tmp"
        )
        let destination = directory.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                // Foundation 的 synchronize 对应文件描述符同步。
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            // 同目录 POSIX rename 原子替换；失败时旧目标保持原状。
            // Apple Foundation 导出所用的系统 C 接口，无需额外框架。
            let status = temporary.path.withCString { source in
                destination.path.withCString { target in
                    rename(source, target)
                }
            }
            guard status == 0 else { throw StateError.writeFailed }
        } catch {
            throw StateError.writeFailed
        }

        // rename 成功后不再执行可能抛错的步骤。
        document = candidate
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        lease.release()
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        while true {
            let capacity = maxStateBytes + 1 - result.count
            guard capacity > 0 else { throw StateError.corrupt }
            let chunk = try handle.read(upToCount: min(capacity, 64 * 1024)) ?? Data()
            if chunk.isEmpty { return result }
            result.append(chunk)
            guard result.count <= maxStateBytes else {
                throw StateError.corrupt
            }
        }
    }
}
