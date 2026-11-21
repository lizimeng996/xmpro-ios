// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit

enum XmlyOrigin: String {
    case mobile = "https://mobile.ximalaya.com"
    case search = "https://www.ximalaya.com"
    case collector = "https://xdcs-collector.ximalaya.com"
    case welfare = "https://m.ximalaya.com"
    case passport = "https://passport.ximalaya.com"

    static var www: XmlyOrigin { .search }
}

enum ProtocolConfig {
    static let version = "3.4.10"
    static let channel = "and-f5"
    static let implementation = "com.ximalaya.ting.lite"
    static let appID = "1463"
    static let device = "android"
    static let collectorUserAgent = "ting_3.4.10.3(Android,30)"
    static let anonymous = "anonymous"

    static let mainAppVersion = "9.5.1"
    static let mainAppChannel = "and-d10"
    static let mainAppImplementation = "com.ximalaya.ting.android"
    static let mainAppUserAgent = "ting_9.5.1(M2102J2SC,Android31)"
    static let deviceModel = "M2102J2SC"
    static let osVersion = "31"
    static let manufacturer = "Xiaomi"

    static let captchaID = "3723312ce42a04b5c0b40e605a882037"
    static let geeTestFields = [
        "captcha_id", "lot_number", "pass_token", "gen_time", "captcha_output"
    ]

    static let qualities = ["m4a_128", "m4a_64", "mp3_64", "mp3_32", "m4a_24"]
    static let XMLY_ALBUM_PAGE_SIZE = 200
    static let listeningValidityMs: Int64 = 180_000
    static let MAX_USAGE_SECONDS = 86_400

    static func originHeaders(origin: String) -> [String: String] {
        origin == XmlyOrigin.collector.rawValue
            ? ["User-Agent": collectorUserAgent, "Accept": "*/*"]
            : [:]
    }

    static func mainAppCookie(for device: String) -> String {
        "1&_device=android&\(device)&9.5.1;channel=and-d10;"
            + "impl=com.ximalaya.ting.android;qimei36=;osversion=31;"
            + "device_model=M2102J2SC;XIM=;net-mode=WIFI;manufacturer=Xiaomi;"
    }

    static func mainAppCookie(for credentials: Credentials) -> String {
        mainAppCookie(for: credentials.deviceId)
    }

    static func liteContext(for credentials: Credentials) -> [String: String] {
        [
            "uid": credentials.uid,
            "token": credentials.tokenAfterUID,
            "device": device,
            "deviceId": credentials.deviceId,
            "version": version,
            "channel": channel,
            "impl": implementation
        ]
    }
}

enum XmlyError: Error, LocalizedError, CustomStringConvertible,
                CustomDebugStringConvertible {
    enum Code: String {
        case invalidEncoding = "invalid_encoding"
        case loginRequired = "login_required"
        case loginExpired = "login_expired"
        case permissionDenied = "permission_denied"
        case rejected = "rejected"
        case badTimestamp = "bad_timestamp"
        case rateLimited = "rate_limited"
        case network = "network"
        case uncertain = "uncertain"
        case invalidJSON = "invalid_json"
        case responseTooLarge = "response_too_large"
        case protocolError = "protocol"
        case invalidCredentials = "invalid_credentials"
        case invalidPage = "invalid_page"
        case invalidResponse = "invalid_response"
        case invalidMobile = "invalid_mobile"
        case invalidCaptcha = "invalid_captcha"
        case invalidCode = "invalid_code"
        case invalidQuota = "invalid_quota"
        case invalidAuthorization = "invalid_authorization"
        case invalidMedia = "invalid_media"
        case invalidHistory = "invalid_history"
        case invalidId = "invalid_id"
        case missingAccount = "missing_account"
        // S2 Round B1 补齐（Kotlin XmlyClient／XmlyHistory 所用字符串码，
        // 原端均有出现；枚举无穷举 switch，加码安全）：
        case invalidSearch = "invalid_search"
        case invalidCatalogue = "invalid_catalogue"
        case incompleteCatalogue = "incomplete_catalogue"
        case idMismatch = "id_mismatch"
        case duplicatePage = "duplicate_page"
        case missingTrack = "missing_track"
        case invalidQuality = "invalid_quality"
        case insufficientQuota = "insufficient_quota"
        case previewOnly = "preview_only"
        case invalidDuration = "invalid_duration"
        case authRequired = "auth_required"
        case repeatedPage = "repeated_page"
        case historyLimit = "history_limit"
        case historyUnconfirmed = "history_unconfirmed"
        // S2 Round B2 补齐（Kotlin XmlyLogin／XmlyExperience 所用字符串码）：
        case invalidDevice = "invalid_device"
        case captchaReused = "captcha_reused"
        case smsCooldown = "sms_cooldown"
        case challengeInvalid = "challenge_invalid"
        case challengeExpired = "challenge_expired"
        case httpError = "http_error"
        case networkError = "network_error"
        case smsSendRejected = "sms_send_rejected"
        case smsVerifyRejected = "sms_verify_rejected"
        case quickLoginRejected = "quick_login_rejected"
        case nonceRejected = "nonce_rejected"
        case invalidHome = "invalid_home"
        case missingAlbum = "missing_album"
        // S4 补齐（Kotlin XmlyExperience.profile / profilePayload 所用字符串码）：
        case profileUnavailable = "profile_unavailable"
    }

    case failure(
        code: Code,
        message: String,
        definitive: Bool = false,
        retryAfter: TimeInterval? = nil
    )

    var code: String {
        switch self {
        case .failure(let code, _, _, _):
            return code.rawValue
        }
    }

    var message: String {
        switch self {
        case .failure(_, let message, _, _):
            return message
        }
    }

    var definitive: Bool {
        switch self {
        case .failure(_, _, let definitive, _):
            return definitive
        }
    }

    var retryAfter: TimeInterval? {
        switch self {
        case .failure(_, _, _, let retryAfter):
            return retryAfter
        }
    }

    var errorDescription: String? { message }

    // Diagnostic rendering intentionally excludes message and associated data.
    var description: String { "XmlyError(\(code))" }
    var debugDescription: String { description }
}

enum ProtocolBytes {
    static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Signature canonical form: keys sorted by UTF-8 byte order, joined
    /// as `k=v&` with a trailing separator.
    ///
    /// Contract: callers only pass protocol-defined ASCII field names.
    /// Unicode keys are out of contract — Swift dictionaries treat
    /// canonically-equivalent strings as equal keys and Swift sorts by
    /// UTF-8 while the JVM sorts by UTF-16, so arbitrary Unicode keys
    /// have no proven cross-runtime equivalence (see BUILD.md).
    static func canonical(_ values: [String: String]) -> String {
        values.keys.sorted(by: utf8Less).map {
            "\($0)=\(values[$0]!)&"
        }.joined()
    }

    static func asciiLowercase(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
    }

    /// For checked, source-controlled hexadecimal protocol constants.
    static func hexBytes(_ string: String) -> [UInt8] {
        let bytes = Array(string.utf8)
        precondition(bytes.count % 2 == 0, "Invalid protocol constant length")
        func nibble(_ byte: UInt8) -> UInt8 {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: preconditionFailure("Invalid protocol constant encoding")
            }
        }
        return stride(from: 0, to: bytes.count, by: 2).map {
            (nibble(bytes[$0]) << 4) | nibble(bytes[$0 + 1])
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 15)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func sha256Hex(_ string: String) -> String {
        hex(Array(CryptoKit.SHA256.hash(data: Data(string.utf8))))
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ string: String) -> [UInt8]? {
        let normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(
            repeating: "=",
            count: (4 - normalized.utf8.count % 4) % 4
        )
        return Data(base64Encoded: padded).map { Array($0) }
    }

    /// 32 字节安全随机 nonce（base64url 无填充，43 字符）。
    /// GeeTest 与登录流程共用同一协议层实现，避免两份随机源漂移。
    static func newNonce() -> String {
        // SystemRandomNumberGenerator 使用系统提供的安全随机源。
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return base64URL(bytes)
    }

    static func fullMatch(_ pattern: String, _ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else {
            return false
        }
        return match.range == range
    }
}
