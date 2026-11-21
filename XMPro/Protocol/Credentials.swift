// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct Credentials: CustomStringConvertible, CustomDebugStringConvertible,
                    CustomReflectable, Sendable {
    let token: String
    let deviceId: String

    init(token: String, deviceId: String) throws {
        // Kotlin trims both inputs before validation.
        let rawToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "1&_token="
        let normalized = rawToken.hasPrefix(prefix)
            ? String(rawToken.dropFirst(prefix.count)) : rawToken
        guard ProtocolBytes.fullMatch(
            #"^[1-9][0-9]{0,19}&[A-Za-z0-9._~+/=\-]{1,8192}$"#,
            normalized
        ), Self.isValidDeviceId(rawDeviceId) else {
            throw Self.invalid
        }
        self.token = normalized
        self.deviceId = rawDeviceId
    }

    /// 凭据可接受的设备字符集（Kotlin 登录 Cookie 的字符集更宽，
    /// 此处为最终边界；登录流程在发送前即用同一校验拒绝，避免走完
    /// 短信+验证+登录才在构造凭据时失败）。
    static func isValidDeviceId(_ deviceId: String) -> Bool {
        ProtocolBytes.fullMatch(
            #"^[A-Za-z0-9_.:\-]{1,128}$"#,
            deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    var uid: String {
        String(token.prefix { $0 != "&" })
    }

    var tokenAfterUID: String {
        String(token.drop(while: { $0 != "&" }).dropFirst())
    }

    var identity: String {
        ProtocolBytes.sha256Hex("\(uid)|\(deviceId)")
    }

    var cacheIdentity: String {
        ProtocolBytes.sha256Hex("\(token)|android&\(deviceId)&3.4.10")
    }

    var cookie: String {
        "1&_token=\(token); 1&_device=android&\(deviceId)&3.4.10; "
            + "channel=and-f5; impl=com.ximalaya.ting.lite; appid=1463"
    }

    var description: String { "Credentials(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["value": "redacted"])
    }

    static func parse(_ input: Any) throws -> Credentials {
        // Bound the untrusted text surface: a real credential export
        // or Cookie is a few KB; reject absurd inputs before parsing.
        if let text = input as? String, text.utf8.count > 1024 * 1024 {
            throw invalid
        }
        var parts = Parts()
        try collect(input, into: &parts, depth: 0)
        guard let token = parts.token, let device = parts.device else {
            throw invalid
        }
        return try Credentials(token: token, deviceId: device)
    }

    static func fromJson(_ map: [String: Any]) throws -> Credentials {
        try parse(map)
    }

    private static var invalid: XmlyError {
        .failure(
            code: .invalidCredentials,
            message: "登录信息格式无效"
        )
    }

    private struct Parts {
        var token: String?
        var device: String?

        mutating func addToken(_ value: String) throws {
            // Normalize before comparing: trim first, then strip the
            // prefix, so the same credential arriving with whitespace
            // from one source and bare from another is not a conflict.
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let prefix = "1&_token="
            let normalized = trimmed.hasPrefix(prefix)
                ? String(trimmed.dropFirst(prefix.count)) : trimmed
            if let token, token != normalized {
                throw Credentials.invalid
            }
            token = normalized
        }

        mutating func addDevice(_ value: String) throws {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let normalized: String
            if trimmed.contains("&") {
                let fields = trimmed.split(
                    separator: "&",
                    omittingEmptySubsequences: false
                )
                guard fields.count == 3,
                      fields[0] == "android",
                      !fields[1].isEmpty,
                      !fields[2].isEmpty else {
                    throw Credentials.invalid
                }
                normalized = String(fields[1])
            } else {
                normalized = trimmed
            }
            if let device, device != normalized {
                throw Credentials.invalid
            }
            device = normalized
        }
    }

    private static func collect(
        _ input: Any,
        into parts: inout Parts,
        depth: Int
    ) throws {
        guard depth <= 16 else {
            throw invalid
        }

        if let text = input as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                let object: Any
                do {
                    object = try JSONSerialization.jsonObject(
                        with: Data(trimmed.utf8)
                    )
                } catch {
                    throw invalid
                }
                guard let map = object as? [String: Any] else {
                    throw invalid
                }
                try collect(map, into: &parts, depth: depth + 1)
            } else {
                try collectCookie(trimmed, into: &parts)
            }
            return
        }

        guard let map = input as? [String: Any] else {
            throw invalid
        }

        for key in ["token", "_token", "1&_token"] {
            if let raw = map[key] {
                guard let value = raw as? String else {
                    throw invalid
                }
                try parts.addToken(value)
            }
        }
        for key in ["device_id", "deviceId", "_device", "1&_device"] {
            if let raw = map[key] {
                guard let value = raw as? String else {
                    throw invalid
                }
                try parts.addDevice(value)
            }
        }
        // A context's `device: android` is not a device identifier.
        if let value = map["device"] as? String, value.contains("&") {
            try parts.addDevice(value)
        }

        for key in ["cookie", "Cookie"] {
            if let raw = map[key] {
                guard let value = raw as? String else {
                    throw invalid
                }
                try collectCookie(value, into: &parts)
            }
        }

        for key in ["xmly", "config"] {
            if let value = map[key] {
                try collect(value, into: &parts, depth: depth + 1)
            }
        }

        if let rawHeaders = map["headers"] {
            guard let headers = rawHeaders as? [String: Any] else {
                throw invalid
            }
            for (key, raw) in headers {
                let lower = ProtocolBytes.asciiLowercase(Array(key.utf8))
                if lower == Array("cookie".utf8) {
                    guard let value = raw as? String else {
                        throw invalid
                    }
                    try collectCookie(value, into: &parts)
                }
            }
        }
    }

    private static func collectCookie(
        _ cookie: String,
        into parts: inout Parts
    ) throws {
        let pattern =
            #"(?:^|[;:\s"'`])1&_(token|device)\s*=\s*([^;\s"'`\\,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw invalid
        }
        let range = NSRange(cookie.startIndex..<cookie.endIndex, in: cookie)
        let matches = regex.matches(in: cookie, range: range)
        guard !matches.isEmpty else {
            throw invalid
        }

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: cookie),
                  let valueRange = Range(match.range(at: 2), in: cookie) else {
                throw invalid
            }
            let name = String(cookie[nameRange])
            let value = String(cookie[valueRange])
            if name == "token" {
                try parts.addToken(value)
            } else {
                try parts.addDevice(value)
            }
        }
    }
}
