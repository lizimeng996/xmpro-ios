// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CommonCrypto
import CryptoKit

enum XmlyCrypto {
    static let playKey = ProtocolBytes.hexBytes(
        "bf56792c145e706d1dd26c04feba6a8c"
    )
    static let durationKey = Array("jkq1hsksjxg4mf2y".utf8)

    private static let ticketMaterial = ProtocolBytes.hexBytes(
        "b0b1a8ac34e66efa95c7f4157cf8b6ba33dfc2075e41fb964f2e12dcaa"
    )
    private static let activityMaterial =
        "q35435432sadks2i3546p2ndkcaqiwurhqfebt4kn"

    private static var decodingError: XmlyError {
        .failure(
            code: .invalidEncoding,
            message: "喜马拉雅播放协议解码失败，可能需要更新客户端协议"
        )
    }

    private static func crypt(
        _ input: [UInt8],
        key: [UInt8],
        operation: CCOperation
    ) throws -> [UInt8] {
        guard key.count == kCCKeySizeAES128 else {
            throw decodingError
        }

        var output = [UInt8](
            repeating: 0,
            count: input.count + kCCBlockSizeAES128
        )
        let capacity = output.count
        var written = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyBuffer in
            input.withUnsafeBytes { inputBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        kCCKeySizeAES128,
                        nil,
                        inputBuffer.baseAddress,
                        input.count,
                        outputBuffer.baseAddress,
                        capacity,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw decodingError
        }
        return Array(output.prefix(written))
    }

    static func encrypt(_ json: String, key: [UInt8]) throws -> String {
        let raw = Array(json.utf8)
        // Deliberate deviation from Kotlin, which sets no such limit;
        // see BUILD.md.
        guard raw.count <= 2 * 1024 * 1024 else {
            throw XmlyError.failure(
                code: .invalidEncoding,
                message: "协议数据过大"
            )
        }

        let encrypted = try crypt(
            raw,
            key: key,
            operation: CCOperation(kCCEncrypt)
        )
        let encoded = Array(ProtocolBytes.base64URL(encrypted).utf8)
        var result: [UInt8] = []
        for start in stride(from: 0, to: encoded.count, by: 76) {
            result.append(contentsOf: encoded[start..<min(start + 76, encoded.count)])
            result.append(10)
        }
        return String(decoding: result, as: UTF8.self)
    }

    static func decrypt(_ value: String, key: [UInt8]) throws -> String {
        let text = value.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        // The size limit applies to the decoded content, not to the
        // line-wrapped transport form: the same ciphertext must not be
        // rejected only because it carries extra CR/LF characters.
        // (Deliberate deviation from Kotlin, which sets no such limit;
        // see BUILD.md.)
        guard text.utf8.count <= 4 * 1024 * 1024 else {
            throw decodingError
        }

        guard ProtocolBytes.fullMatch(
            #"^[A-Za-z0-9+/_\-]*={0,2}$"#,
            text
        ), let bytes = ProtocolBytes.decodeBase64URL(text),
           !bytes.isEmpty,
           bytes.count % kCCBlockSizeAES128 == 0 else {
            throw decodingError
        }

        do {
            let decrypted = try crypt(
                bytes,
                key: key,
                operation: CCOperation(kCCDecrypt)
            )
            // Swift replaces malformed UTF-8 sequences with U+FFFD, as
            // Kotlin's UTF-8 conversion does, but the replacement
            // granularity for malformed sequences (e.g. lone surrogates)
            // is not proven identical across runtimes; a Kotlin
            // cross-check vector is still needed for that boundary.
            return String(decoding: decrypted, as: UTF8.self)
        } catch {
            throw decodingError
        }
    }

    /// Decodes a listening-time field: AES envelope with the duration key,
    /// plaintext form `value|millisecondTimestamp` (Kotlin `XmlyClient`
    /// `decode`). The timestamp must be within `listeningValidityMs` of
    /// the corrected clock; anything malformed, unparseable, or stale
    /// maps to the same `invalid_quota` error, never to a partial value.
    /// The divider is the *last* `|`, so the value itself may contain `|`.
    static func decodeDurationField(
        _ envelope: String,
        nowMs: Int64 = ServerClock.shared.now()
    ) throws -> String {
        let plain: String
        do {
            plain = try decrypt(envelope, key: durationKey)
        } catch {
            throw invalidQuota
        }
        guard let divider = plain.lastIndex(of: "|") else {
            throw invalidQuota
        }
        let stampText = String(plain[plain.index(after: divider)...])
        guard let stamp = Int64(stampText) else {
            throw invalidQuota
        }
        let difference = nowMs.subtractingReportingOverflow(stamp)
        guard !difference.overflow,
              difference.partialValue.magnitude
                < UInt64(ProtocolConfig.listeningValidityMs) else {
            throw invalidQuota
        }
        return String(plain[..<divider])
    }

    private static var invalidQuota: XmlyError {
        .failure(code: .invalidQuota, message: "听时信息缺失或已过期")
    }

    static func activitySignature(_ params: [String: String]) -> String {
        let canonical = ProtocolBytes.canonical(params) + activityMaterial
        return MD5.hex(ProtocolBytes.asciiLowercase(Array(canonical.utf8)))
    }

    /// Version/variant bits are set on the UUID bytes, exactly like Kotlin's
    /// `freshTicket` (which masks the random bytes before use). This matters
    /// for the fixed golden vector: its UUID already carries the masked bits.
    static func freshTicket(
        credentials: Credentials,
        attributes: String? = nil,
        nowSeconds: Int64? = nil,
        uuidBytes: [UInt8]? = nil
    ) throws -> String {
        let supplied: [UInt8]
        if let uuidBytes {
            guard uuidBytes.count == 16 else {
                throw XmlyError.failure(
                    code: .invalidEncoding,
                    message: "协议数据格式无效"
                )
            }
            supplied = uuidBytes
        } else {
            var uuid = UUID().uuid
            supplied = withUnsafeBytes(of: &uuid) { Array($0) }
        }
        var randomBytes = supplied
        randomBytes[6] = (randomBytes[6] & 0x0F) | 0x40
        randomBytes[8] = (randomBytes[8] & 0x3F) | 0x80

        let identity = MD5.digest(
            Array("\(credentials.uid)|\(credentials.deviceId)".utf8)
        )
        let seconds = nowSeconds ?? (ServerClock.shared.now() / 1000)
        let timestamp = UInt32(truncatingIfNeeded: seconds)

        var payload: [UInt8] = [
            UInt8(truncatingIfNeeded: timestamp >> 24),
            UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8),
            UInt8(truncatingIfNeeded: timestamp)
        ]
        payload.append(contentsOf: identity)
        for index in 0..<16 {
            payload.append(randomBytes[index] ^ identity[index])
        }

        let suffix = Array((
            "com.ximalaya.ting.lite!1.3.24!3.4.10.3!"
                + (attributes
                    ?? "b=lite&s=lite_track_play_url&&u=\(credentials.uid)")
        ).utf8)

        let signed = payload + Array("TAC".utf8) + ticketMaterial + suffix
        let digest = Array(CryptoKit.SHA256.hash(data: Data(signed)))
        return "TAC" + ProtocolBytes.base64URL(payload + digest + suffix)
    }

    static func welfareAttributes(for credentials: Credentials) -> String {
        "b=lite&s=lite_time_reward&u=\(credentials.uid)"
    }
}
