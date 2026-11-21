// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

enum Signatures {
    private static let historyMaterial =
        "23627d1451047b8d257a96af5db359538f081d651df75b4aa169508547208159"
    private static let loginSalt =
        "MOBILE-V1-PRODUCT-7D74899B338B4F348E2383970CC09991E8E8D8F2BC744EF0BEE94D76D718C089"
    private static let rewardSalt =
        "0ab3443b71834b33be675af744d76ef0aaa74cd2b60c4b67"

    private static let modulus =
        "9585a4773abeecb949701d49762f2dfab9599ba19dfe1e1a2fa200e32e0444f426da528912"
        + "d9ea8669515f6f1014c454e1343b97abf7c10fe49d520a6999c66b230e0730c3f8"
        + "02d136a892501ff2b13d699b5c7ecbbfef428ac36d3d83a5bd627f18746a7fdc77"
        + "4c12a38de2760a3b95c653c10d7eb7f84722976251f649556b"

    static func history(_ params: [String: String]) -> String {
        MD5.hex(ProtocolBytes.asciiLowercase(
            Array((ProtocolBytes.canonical(params) + historyMaterial).utf8)
        ))
    }

    static func login(_ values: [String: String]) -> String {
        // Kotlin uppercase() is locale-independent Unicode uppercasing.
        // Unlike history/activity, this must not ASCII-lowercase the input.
        let canonical = ProtocolBytes.canonical(values).uppercased()
        return SHA1.hex(canonical + loginSalt)
    }

    static func reward(
        requestId: String,
        uid: String,
        timestamp: Int64 = ServerClock.shared.now(),
        secondPhase: String? = nil
    ) -> String {
        var parts = "\(requestId)&\(uid)&\(timestamp)"
        if let secondPhase {
            parts += "&\(secondPhase)"
        }
        return MD5.hex(parts + "&" + rewardSalt)
    }

    /// Returns exactly `count` cryptographically random bytes or a sanitized error.
    static func secureRandomBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0 else {
            throw rsaError
        }
        if count == 0 {
            return []
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw rsaError
        }
        return bytes
    }

    /// The injected source must return exactly the requested number of bytes.
    /// Zero bytes are rejected individually, matching Kotlin's rejection sampling.
    static func pkcs1v15Block(
        message: [UInt8],
        randomBytes: (Int) throws -> [UInt8]
    ) throws -> [UInt8] {
        guard message.count <= 117 else {
            throw XmlyError.failure(
                code: .invalidMobile,
                message: "手机号格式无效"
            )
        }

        let separator = 128 - message.count - 1
        var block = [UInt8](repeating: 0, count: 128)
        block[1] = 2
        var index = 2
        var emptyRounds = 0

        while index < separator {
            let needed = separator - index
            // Map any injected-source failure to the fixed redacted
            // error: the raw error must not escape the RSA boundary.
            let bytes: [UInt8]
            do {
                bytes = try randomBytes(needed)
            } catch {
                throw rsaError
            }
            guard bytes.count == needed else {
                throw rsaError
            }
            let previousIndex = index
            for byte in bytes where byte != 0 {
                block[index] = byte
                index += 1
            }
            if index == previousIndex {
                emptyRounds += 1
                // Prevent a broken injected source from hanging indefinitely.
                guard emptyRounds < 1024 else {
                    throw rsaError
                }
            } else {
                emptyRounds = 0
            }
        }

        block[separator] = 0
        block.replaceSubrange((separator + 1)..<128, with: message)
        return block
    }

    static func encryptMobile(
        _ mobile: String,
        randomBytes: (Int) throws -> [UInt8] = Signatures.secureRandomBytes
    ) throws -> String {
        let block = try pkcs1v15Block(
            message: Array(mobile.utf8),
            randomBytes: randomBytes
        )
        let key = try makePublicKey()
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else {
            throw rsaError
        }

        var error: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionRaw,
            Data(block) as CFData,
            &error
        ) else {
            // Consume the Security error object per its ownership rules;
            // the failure itself stays redacted.
            error?.release()
            throw rsaError
        }
        let data = encrypted as Data
        guard data.count == 128 else {
            throw rsaError
        }
        return data.base64EncodedString()
    }

    private static var rsaError: XmlyError {
        .failure(code: .invalidEncoding, message: "手机号加密失败")
    }

    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 128 {
            return [UInt8(count)]
        }
        var value = count
        var bytes: [UInt8] = []
        while value != 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    private static func makePublicKey() throws -> SecKey {
        let modulusBytes = ProtocolBytes.hexBytes(modulus)
        guard modulusBytes.count == 128 else {
            throw rsaError
        }

        // DER INTEGER is signed; the leading zero keeps the modulus positive.
        let rsaPublicKey = der(
            0x30,
            der(0x02, [0] + modulusBytes) + der(0x02, [0x01, 0x00, 0x01])
        )
        let algorithmIdentifier: [UInt8] = [
            0x30, 0x0d,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
            0x05, 0x00
        ]
        let subjectPublicKeyInfo = der(
            0x30,
            algorithmIdentifier + der(0x03, [0] + rsaPublicKey)
        )
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 1024
        ]

        var spkiError: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(
            Data(subjectPublicKeyInfo) as CFData,
            attributes as CFDictionary,
            &spkiError
        ) {
            return key
        }
        // Consume the SPKI error object before falling back; the
        // failure itself stays redacted.
        spkiError?.release()

        // Security's documented RSA external representation is PKCS#1.
        // Use the identical RSAPublicKey contained in the SPKI if SPKI is rejected.
        var pkcs1Error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(
            Data(rsaPublicKey) as CFData,
            attributes as CFDictionary,
            &pkcs1Error
        ) else {
            pkcs1Error?.release()
            throw rsaError
        }
        return key
    }
}
