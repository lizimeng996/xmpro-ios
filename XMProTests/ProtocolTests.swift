// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import XCTest
@testable import XMPro

final class ProtocolTests: XCTestCase {
    /*
     golden_vectors.json must belong to the test target's Copy Bundle Resources.

     Sources:
     - Two activity samples: original XmlyCryptoTest, independently rechecked
       with Python.
     - Two additional original-repository activity vectors are asserted below.
     - History/login/reward: independent Python cross-checks; the original
       repository did not provide ready-made vectors for these.
     - ticket_fixed: complete ticket using fixed random bytes, compared exactly.

     Failure messages never include credential, Cookie, plaintext, ticket,
     encrypted mobile, or complete digest values. Equality failures report
     only a case name and expected/actual byte counts.

     Test contract: tests use the module's internal API through
     `@testable import` (the module-internal testable contract). The
     module intentionally exposes no public API surface yet; a public
     API, if ever needed for an app extension or package split, is a
     separate decision.
     */

    private struct FixtureError: Error, CustomStringConvertible {
        var description: String { "Invalid golden vector structure" }
    }

    private func vectors() throws -> [String: Any] {
        let bundle = Bundle(for: ProtocolTests.self)
        guard let url = bundle.url(
            forResource: "golden_vectors",
            withExtension: "json"
        ) else {
            XCTFail("golden_vectors.json: missing test bundle resource")
            throw FixtureError()
        }
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                XCTFail("golden_vectors.json: invalid root")
                throw FixtureError()
            }
            return root
        } catch {
            XCTFail("golden_vectors.json: unable to load valid JSON")
            throw FixtureError()
        }
    }

    private func object(
        _ root: [String: Any],
        _ key: String
    ) throws -> [String: Any] {
        guard let result = root[key] as? [String: Any] else {
            XCTFail("golden_vectors.json: missing object field")
            throw FixtureError()
        }
        return result
    }

    private func objects(
        _ root: [String: Any],
        _ key: String
    ) throws -> [[String: Any]] {
        guard let result = root[key] as? [[String: Any]] else {
            XCTFail("golden_vectors.json: missing array field")
            throw FixtureError()
        }
        return result
    }

    private func string(
        _ root: [String: Any],
        _ key: String
    ) throws -> String {
        guard let result = root[key] as? String else {
            XCTFail("golden_vectors.json: missing string field")
            throw FixtureError()
        }
        return result
    }

    private func stringMap(
        _ root: [String: Any],
        _ key: String
    ) throws -> [String: String] {
        guard let result = root[key] as? [String: String] else {
            XCTFail("golden_vectors.json: missing string map")
            throw FixtureError()
        }
        return result
    }

    private func integer(
        _ root: [String: Any],
        _ key: String
    ) throws -> Int64 {
        guard let result = root[key] as? NSNumber else {
            XCTFail("golden_vectors.json: missing integer field")
            throw FixtureError()
        }
        return result.int64Value
    }

    private func assertSame(
        _ actual: String,
        _ expected: String,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertSame(
            Array(actual.utf8), Array(expected.utf8), name,
            file: file, line: line
        )
    }

    private func assertSame(
        _ actual: [UInt8],
        _ expected: [UInt8],
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard actual == expected else {
            XCTFail(
                "\(name): expected length \(expected.count), actual length \(actual.count)",
                file: file,
                line: line
            )
            return
        }
    }

    private func expectCode(
        _ expected: String,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail("\(name): expected an error", file: file, line: line)
        } catch let error as XmlyError {
            if error.code != expected {
                XCTFail("\(name): unexpected error code", file: file, line: line)
            }
        } catch {
            XCTFail("\(name): unexpected error type", file: file, line: line)
        }
    }

    private func fixtureBytes(_ hex: String) throws -> [UInt8] {
        guard hex.utf8.count % 2 == 0,
              ProtocolBytes.fullMatch(#"^[A-Fa-f0-9]*$"#, hex) else {
            XCTFail("golden_vectors.json: invalid hex field")
            throw FixtureError()
        }
        return ProtocolBytes.hexBytes(hex)
    }

    private func fixtureCredentials(
        uid: String = "123456",
        deviceId: String = "android-0123456789abcdef"
    ) throws -> Credentials {
        // Synthetic local fixture; never a user credential.
        try Credentials(
            token: "\(uid)&fixture-token",
            deviceId: deviceId
        )
    }

    func testMD5RFC1321Vectors() {
        let samples = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            (
                "abcdefghijklmnopqrstuvwxyz",
                "c3fcd3d76192e4007dfb496cca67e13b"
            ),
            (
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
                "d174ab98d277d9f5a5611c2c9f419d9f"
            ),
            (
                "12345678901234567890123456789012345678901234567890123456789012345678901234567890",
                "57edf4a22be3c955ac49da2e2107b67a"
            )
        ]
        for (index, sample) in samples.enumerated() {
            assertSame(MD5.hex(sample.0), sample.1, "md5.\(index)")
        }
    }

    func testSHA1Vectors() {
        let samples = [
            ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
            ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
            )
        ]
        for (index, sample) in samples.enumerated() {
            assertSame(SHA1.hex(sample.0), sample.1, "sha1.\(index)")
        }
    }

    func testByteCanonicalization() {
        let input: [UInt8] = [65, 90, 97, 0xc3, 0x84]
        assertSame(
            ProtocolBytes.asciiLowercase(input),
            [97, 122, 97, 0xc3, 0x84],
            "ascii.lower"
        )
        assertSame(
            ProtocolBytes.canonical(["中": "3", "é": "2", "z": "1"]),
            "z=1&é=2&中=3&",
            "utf8.order"
        )
    }

    func testEnvelopeGoldenVectorsAndRoundTrips() throws {
        let root = try vectors()
        let samples: [(String, [UInt8])] = [
            ("envelope_play", XmlyCrypto.playKey),
            ("envelope_duration", XmlyCrypto.durationKey)
        ]

        for (name, key) in samples {
            let sample = try object(root, name)
            let json = try string(sample, "json")
            let expected = try string(sample, "envelope")
            let encrypted = try XmlyCrypto.encrypt(json, key: key)

            assertSame(encrypted, expected, "\(name).exact")
            XCTAssertTrue(encrypted.hasSuffix("\n"), "\(name).trailingNewline")
            let lines = encrypted.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            XCTAssertTrue(lines.last?.isEmpty == true, "\(name).lastLine")
            for line in lines.dropLast().dropLast() {
                XCTAssertEqual(line.utf8.count, 76, "\(name).lineWidth")
            }

            assertSame(
                try XmlyCrypto.decrypt(encrypted, key: key),
                json,
                "\(name).roundTrip"
            )
            assertSame(
                try XmlyCrypto.decrypt(expected, key: key),
                json,
                "\(name).decryptGolden"
            )

            let compact = expected.replacingOccurrences(of: "\n", with: "")
            assertSame(
                try XmlyCrypto.decrypt(compact, key: key),
                json,
                "\(name).compact"
            )
            assertSame(
                try XmlyCrypto.decrypt(
                    expected.replacingOccurrences(of: "\n", with: "\r\n"),
                    key: key
                ),
                json,
                "\(name).crlf"
            )
        }
    }

    func testEnvelopeRejectsInvalidEncoding() {
        for (index, value) in ["", "not base64!!", "QUJD"].enumerated() {
            expectCode("invalid_encoding", name: "envelope.invalid.\(index)") {
                _ = try XmlyCrypto.decrypt(value, key: XmlyCrypto.playKey)
            }
        }
    }

    func testActivitySignatures() throws {
        let samples = try objects(try vectors(), "activity_signature_samples")
        XCTAssertEqual(samples.count, 2, "activity.fixtureCount")
        for (index, sample) in samples.enumerated() {
            assertSame(
                XmlyCrypto.activitySignature(try stringMap(sample, "params")),
                try string(sample, "signature"),
                "activity.golden.\(index)"
            )
        }
        assertSame(
            XmlyCrypto.activitySignature(["a": "b", "z": "Z"]),
            "a6fec7af506479d08f411bf040d8c762",
            "activity.repository.0"
        )
        assertSame(
            XmlyCrypto.activitySignature(["uid": "123", "count": "2"]),
            "4a8f64e65478ecc6c823c708bb70c9b0",
            "activity.repository.1"
        )
    }

    func testHistorySignature() throws {
        let sample = try object(try vectors(), "history_signature_sample")
        assertSame(
            Signatures.history(try stringMap(sample, "params")),
            try string(sample, "signature"),
            "history.golden"
        )
    }

    func testLoginSignature() throws {
        let sample = try object(try vectors(), "login_signature_sample")
        assertSame(
            Signatures.login(try stringMap(sample, "values")),
            try string(sample, "signature"),
            "login.golden"
        )
    }

    func testRewardSignatures() throws {
        let samples = try objects(try vectors(), "reward_signature_samples")
        XCTAssertEqual(samples.count, 2, "reward.fixtureCount")
        for (index, sample) in samples.enumerated() {
            assertSame(
                Signatures.reward(
                    requestId: try string(sample, "requestId"),
                    uid: try string(sample, "uid"),
                    timestamp: try integer(sample, "timestamp"),
                    secondPhase: sample["secondPhase"] as? String
                ),
                try string(sample, "signature"),
                "reward.golden.\(index)"
            )
        }
    }

    func testFixedTicketAndStructure() throws {
        let sample = try object(try vectors(), "ticket_fixed")
        let uid = try string(sample, "uid")
        let credentials = try fixtureCredentials(
            uid: uid,
            deviceId: string(sample, "deviceId")
        )
        let seconds = try integer(sample, "nowSeconds")
        let uuid = try fixtureBytes(string(sample, "uuidHex"))
        let attributes = sample["attributes"] as? String
        let ticket = try XmlyCrypto.freshTicket(
            credentials: credentials,
            attributes: attributes,
            nowSeconds: seconds,
            uuidBytes: uuid
        )

        assertSame(ticket, try string(sample, "ticket"), "ticket.fixed")
        XCTAssertTrue(ticket.hasPrefix("TAC"), "ticket.prefix")

        guard let body = ProtocolBytes.decodeBase64URL(
            String(ticket.dropFirst(3))
        ) else {
            XCTFail("ticket.structure: invalid base64url")
            return
        }
        let suffix = "com.ximalaya.ting.lite!1.3.24!3.4.10.3!"
            + (attributes ?? "b=lite&s=lite_track_play_url&&u=\(uid)")
        XCTAssertEqual(
            body.count, 4 + 16 + 16 + 32 + suffix.utf8.count,
            "ticket.bodyLength"
        )
        guard body.count >= 68 else {
            XCTFail("ticket.structure: truncated body")
            return
        }
        let timestamp = body.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        XCTAssertEqual(timestamp, 1_700_000_000, "ticket.timestamp")

        assertSame(
            Array(body.suffix(suffix.utf8.count)),
            Array(suffix.utf8),
            "ticket.suffix"
        )
        let identity = MD5.digest(Array("\(uid)|\(credentials.deviceId)".utf8))
        assertSame(Array(body[4..<20]), identity, "ticket.identity")
        // Kotlin masks the UUID version/variant bits before the XOR, so the
        // expectation must use the same masked bytes as the implementation.
        var maskedUUID = uuid
        maskedUUID[6] = (maskedUUID[6] & 0x0F) | 0x40
        maskedUUID[8] = (maskedUUID[8] & 0x3F) | 0x80
        assertSame(
            Array(body[20..<36]),
            zip(maskedUUID, identity).map { $0.0 ^ $0.1 },
            "ticket.uuidXor"
        )
    }

    func testTicketCustomAttributes() throws {
        let credentials = try fixtureCredentials()
        let attributes = XmlyCrypto.welfareAttributes(for: credentials)
        let ticket = try XmlyCrypto.freshTicket(
            credentials: credentials,
            attributes: attributes,
            nowSeconds: 1_700_000_000,
            uuidBytes: [UInt8](repeating: 0x5a, count: 16)
        )
        guard let body = ProtocolBytes.decodeBase64URL(
            String(ticket.dropFirst(3))
        ) else {
            XCTFail("ticket.custom: invalid base64url")
            return
        }
        let suffix = "com.ximalaya.ting.lite!1.3.24!3.4.10.3!" + attributes
        assertSame(
            Array(body.suffix(suffix.utf8.count)),
            Array(suffix.utf8),
            "ticket.customSuffix"
        )
    }

    func testPKCS1V15DeterministicBlock() throws {
        let message = Array("13800138000".utf8)
        let block = try Signatures.pkcs1v15Block(
            message: message,
            randomBytes: { count in [UInt8](repeating: 0xa5, count: count) }
        )
        XCTAssertEqual(block.count, 128, "rsa.blockLength")
        guard block.count == 128 else { return }
        XCTAssertEqual(block[0], 0, "rsa.firstByte")
        XCTAssertEqual(block[1], 2, "rsa.blockType")
        let separator = 128 - message.count - 1
        XCTAssertTrue(
            block[2..<separator].allSatisfy { $0 != 0 },
            "rsa.nonzeroPadding"
        )
        assertSame(
            Array(block[2..<separator]),
            [UInt8](repeating: 0xa5, count: separator - 2),
            "rsa.deterministicPadding"
        )
        XCTAssertEqual(block[separator], 0, "rsa.separator")
        assertSame(
            Array(block[(separator + 1)..<128]),
            message,
            "rsa.messageTail"
        )
    }

    func testPKCS1V15RejectsZeroRandomBytes() throws {
        var calls = 0
        let block = try Signatures.pkcs1v15Block(
            message: Array("13800138000".utf8),
            randomBytes: { count in
                calls += 1
                return [UInt8](repeating: calls == 1 ? 0 : 7, count: count)
            }
        )
        XCTAssertEqual(calls, 2, "rsa.rejectionSampling")
        XCTAssertTrue(block[2..<116].allSatisfy { $0 == 7 }, "rsa.resampled")
    }

    func testRSAOutputAndLengthLimit() throws {
        let encrypted = try Signatures.encryptMobile("13800138000")
        XCTAssertTrue(
            ProtocolBytes.fullMatch(#"^[A-Za-z0-9+/]+={0,2}$"#, encrypted),
            "rsa.standardBase64"
        )
        XCTAssertTrue(encrypted.hasSuffix("="), "rsa.base64Padding")
        guard let data = Data(base64Encoded: encrypted) else {
            XCTFail("rsa.output: invalid base64")
            return
        }
        XCTAssertEqual(data.count, 128, "rsa.outputLength")

        expectCode("invalid_mobile", name: "rsa.longMobile") {
            _ = try Signatures.pkcs1v15Block(
                message: [UInt8](repeating: 49, count: 118),
                randomBytes: { [UInt8](repeating: 1, count: $0) }
            )
        }
    }

    func testCredentialsParsingAndIdentity() throws {
        let expected = try fixtureCredentials()
        let map: [String: Any] = [
            "token": expected.token,
            "deviceId": expected.deviceId
        ]
        let json = try JSONSerialization.data(withJSONObject: map)
        let inputs: [Any] = [
            expected.cookie,
            String(decoding: json, as: UTF8.self),
            map,
            ["xmly": map],
            ["config": ["xmly": map]],
            ["headers": ["cookie": expected.cookie]]
        ]

        for (index, input) in inputs.enumerated() {
            let parsed = try Credentials.parse(input)
            assertSame(parsed.token, expected.token, "credentials.token.\(index)")
            assertSame(
                parsed.deviceId, expected.deviceId, "credentials.device.\(index)"
            )
        }

        let prefixed = try Credentials(
            token: "1&_token=" + expected.token,
            deviceId: expected.deviceId
        )
        assertSame(prefixed.token, expected.token, "credentials.prefix")

        let identity = ProtocolBytes.hex(Array(CryptoKit.SHA256.hash(
            data: Data("\(expected.uid)|\(expected.deviceId)".utf8)
        )))
        assertSame(expected.identity, identity, "credentials.identity")

        let cacheIdentity = ProtocolBytes.hex(Array(CryptoKit.SHA256.hash(
            data: Data(
                "\(expected.token)|android&\(expected.deviceId)&3.4.10".utf8
            )
        )))
        assertSame(
            expected.cacheIdentity, cacheIdentity, "credentials.cacheIdentity"
        )
        assertSame(
            expected.description, "Credentials(redacted)",
            "credentials.description"
        )
        assertSame(
            String(reflecting: expected), "Credentials(redacted)",
            "credentials.debugDescription"
        )
        XCTAssertFalse(
            expected.description.contains(expected.token),
            "credentials.descriptionRedaction"
        )
        let context = ProtocolConfig.liteContext(for: expected)
        XCTAssertEqual(context.count, 7, "credentials.contextCount")
        assertSame(
            context["token"] ?? "", expected.tokenAfterUID,
            "credentials.contextToken"
        )
    }

    func testCredentialsRejectInvalidAndConflictingInput() throws {
        let expected = try fixtureCredentials()

        for (index, token) in [
            "0&fixture",
            "123",
            "123&",
            "123&bad value",
            "123&fix\nture",
            String(repeating: "1", count: 21) + "&fixture"
        ].enumerated() {
            expectCode(
                "invalid_credentials",
                name: "credentials.invalidToken.\(index)"
            ) {
                _ = try Credentials(token: token, deviceId: expected.deviceId)
            }
        }

        for (index, device) in [
            "", "bad device", "device&bad", "中文", String(repeating: "a", count: 129)
        ].enumerated() {
            expectCode(
                "invalid_credentials",
                name: "credentials.invalidDevice.\(index)"
            ) {
                _ = try Credentials(token: expected.token, deviceId: device)
            }
        }

        expectCode("invalid_credentials", name: "credentials.conflictingToken") {
            _ = try Credentials.parse(
                expected.cookie + "; 1&_token=987654&other-fixture"
            )
        }
        expectCode("invalid_credentials", name: "credentials.conflictingDevice") {
            _ = try Credentials.parse(
                expected.cookie + "; 1&_device=android&different-fixture&3.4.10"
            )
        }
        expectCode("invalid_credentials", name: "credentials.conflictingNested") {
            _ = try Credentials.parse([
                "token": expected.token,
                "deviceId": expected.deviceId,
                "xmly": [
                    "token": "987654&other-fixture",
                    "deviceId": expected.deviceId
                ]
            ])
        }

        let repeated = try Credentials.parse(
            expected.cookie + "; " + expected.cookie
        )
        assertSame(
            repeated.identity, expected.identity, "credentials.identicalDuplicates"
        )
    }

    func testServerClockSecondsNormalization() {
        let base: Int64 = 1_700_000_000_000
        let clock = ServerClock {
            Date(timeIntervalSince1970: TimeInterval(base) / 1000)
        }
        XCTAssertFalse(clock.synced, "clock.initial")
        clock.observeMillis((base + 5000) / 1000)
        XCTAssertEqual(clock.now(), base + 5000, "clock.seconds")
        XCTAssertTrue(clock.synced, "clock.synced")
    }

    func testServerClockIgnoresSmallAndExcessiveDrift() {
        let base: Int64 = 1_700_000_000_000
        let clock = ServerClock {
            Date(timeIntervalSince1970: TimeInterval(base) / 1000)
        }

        clock.observeMillis(base + 999)
        XCTAssertEqual(clock.now(), base, "clock.smallPositive")
        clock.observeMillis(base - 999)
        XCTAssertEqual(clock.now(), base, "clock.smallNegative")
        XCTAssertFalse(clock.synced, "clock.smallUnsynced")

        clock.observeMillis(base + 86_400_001)
        clock.observeMillis(base - 86_400_001)
        XCTAssertEqual(clock.now(), base, "clock.excessive")
        XCTAssertFalse(clock.synced, "clock.excessiveUnsynced")

        clock.observeMillis(base + 5000)
        clock.observeMillis(base + 999)
        clock.observeMillis(base + 86_400_001)
        XCTAssertEqual(clock.now(), base + 5000, "clock.preservesOffset")
    }

    func testServerClockDateHeaderAndPayload() {
        let base: Int64 = 1_700_000_000_000
        let clock = ServerClock {
            Date(timeIntervalSince1970: TimeInterval(base) / 1000)
        }

        clock.observeDateHeader("Tue, 14 Nov 2023 22:13:25 GMT")
        XCTAssertEqual(clock.now(), base + 5000, "clock.rfc1123")
        clock.observeDateHeader("invalid")
        XCTAssertEqual(clock.now(), base + 5000, "clock.invalidDate")

        clock.observePayload(timestamp: "1700000010")
        XCTAssertEqual(clock.now(), base + 10_000, "clock.stringPayload")
        clock.observePayload(timestamp: NSNumber(value: base + 20_000))
        XCTAssertEqual(clock.now(), base + 20_000, "clock.numericPayload")
        clock.observePayload(timestamp: nil)
        XCTAssertEqual(clock.now(), base + 20_000, "clock.missingPayload")
    }

    // MARK: - S1 review fixes

    func testDurationFieldDecoding() throws {
        let nowMs: Int64 = 1_700_000_000_000
        func envelope(_ plain: String) throws -> String {
            try XmlyCrypto.encrypt(plain, key: XmlyCrypto.durationKey)
        }

        assertSame(
            try XmlyCrypto.decodeDurationField(
                try envelope("1800|\(nowMs)"), nowMs: nowMs
            ),
            "1800",
            "duration.valid"
        )
        // The divider is the last '|', so the value may contain '|'.
        assertSame(
            try XmlyCrypto.decodeDurationField(
                try envelope("a|b|\(nowMs)"), nowMs: nowMs
            ),
            "a|b",
            "duration.pipeInValue"
        )
        // Freshness boundary: |now - stamp| < 180_000 is valid.
        assertSame(
            try XmlyCrypto.decodeDurationField(
                try envelope("1800|\(nowMs - 179_999)"), nowMs: nowMs
            ),
            "1800",
            "duration.freshPast"
        )
        assertSame(
            try XmlyCrypto.decodeDurationField(
                try envelope("1800|\(nowMs + 179_999)"), nowMs: nowMs
            ),
            "1800",
            "duration.freshFuture"
        )

        // An empty value with a valid stamp decodes to "" (Kotlin
        // returns substring(0, divider) as-is); S2 rejects it when
        // parsing the value as a number.
        assertSame(
            try XmlyCrypto.decodeDurationField(
                try envelope("|\(nowMs)"), nowMs: nowMs
            ),
            "",
            "duration.emptyValue"
        )

        for (index, plain) in [
            "1800|\(nowMs - 180_000)",
            "1800|\(nowMs + 180_000)",
            "1800",
            "1800|not-a-number",
            "1800|",
        ].enumerated() {
            expectCode(
                "invalid_quota",
                name: "duration.invalid.\(index)"
            ) {
                _ = try XmlyCrypto.decodeDurationField(
                    try envelope(plain), nowMs: nowMs
                )
            }
        }
        expectCode("invalid_quota", name: "duration.undecryptable") {
            _ = try XmlyCrypto.decodeDurationField(
                "not base64!!", nowMs: nowMs
            )
        }
    }

    func testEnvelopeEmptyPlaintextAndSizeBoundaries() throws {
        let key = XmlyCrypto.playKey
        // Empty plaintext: PKCS7 still yields one full block.
        assertSame(
            try XmlyCrypto.decrypt(
                try XmlyCrypto.encrypt("", key: key), key: key
            ),
            "",
            "envelope.empty"
        )
        // The 2 MiB plaintext limit is inclusive.
        let atLimit = String(repeating: "a", count: 2 * 1024 * 1024)
        XCTAssertNoThrow(
            try XmlyCrypto.encrypt(atLimit, key: key),
            "envelope.atLimit"
        )
        expectCode("invalid_encoding", name: "envelope.overLimit") {
            _ = try XmlyCrypto.encrypt(
                String(repeating: "a", count: 2 * 1024 * 1024 + 1),
                key: key
            )
        }
        // The 4 MiB ciphertext limit counts the stripped content.
        expectCode("invalid_encoding", name: "envelope.cipherOverLimit") {
            _ = try XmlyCrypto.decrypt(
                String(repeating: "A", count: 4 * 1024 * 1024 + 1),
                key: key
            )
        }
        // Extra line wrapping alone must not trip the limit.
        let sample = try object(try vectors(), "envelope_play")
        let expected = try string(sample, "envelope")
        let wrapped = expected
            + String(repeating: "\n", count: 4 * 1024 * 1024)
        assertSame(
            try XmlyCrypto.decrypt(wrapped, key: key),
            try string(sample, "json"),
            "envelope.wrappedOverLimit"
        )
        // Wrong key length and truncated ciphertext are deterministic.
        expectCode("invalid_encoding", name: "envelope.shortKey") {
            _ = try XmlyCrypto.decrypt(
                expected, key: [UInt8](repeating: 0, count: 15)
            )
        }
        let compact = expected.replacingOccurrences(of: "\n", with: "")
        expectCode("invalid_encoding", name: "envelope.truncated") {
            _ = try XmlyCrypto.decrypt(String(compact.dropLast(2)), key: key)
        }
    }

    func testEnvelopeDecryptsInvalidUTF8Leniently() throws {
        // Plaintext 15 x 0xFF + 0x01 padding: valid PKCS7, invalid UTF-8.
        // Produced with the Python reference implementation (play key).
        let decrypted = try XmlyCrypto.decrypt(
            "KPQS-Y0QxBrSZJjKCbqw4g", key: XmlyCrypto.playKey
        )
        XCTAssertTrue(
            decrypted.contains("\u{FFFD}"),
            "envelope.invalidUTF8Replacement"
        )
    }

    func testRSAFixedPaddingGoldenCiphertext() throws {
        // Fixed 0xA5 padding; expected ciphertext computed independently
        // in Python as pow(block, 65537, n) over the public modulus.
        let encrypted = try Signatures.encryptMobile(
            "13800138000",
            randomBytes: { count in [UInt8](repeating: 0xa5, count: count) }
        )
        assertSame(
            encrypted,
            "L9TMNHd5C7UX1JWlCuOd+qq0ZaoOSnKeevp65RJPlxcdHW7dWCBIblDxRHhWsYCYm5wM2LSbtbcVCEEb/FlqNCz58hu0+9pN1kdaRzyw7lW6oAneJlN2qY05PwCP+VDzq+fy5Yj8tOKDxgqRXi1cw3B8nxrqekQ/zFgRQHp/TgM=",
            "rsa.fixedPaddingCiphertext"
        )
    }

    func testTicketTimestampWraparoundAndUUIDLength() throws {
        let sample = try object(try vectors(), "ticket_fixed")
        let credentials = try fixtureCredentials(
            uid: try string(sample, "uid"),
            deviceId: string(sample, "deviceId")
        )
        let uuid = try fixtureBytes(string(sample, "uuidHex"))
        // nowSeconds wraps at UInt32: +2^32 must yield the same ticket.
        let wrapped = try XmlyCrypto.freshTicket(
            credentials: credentials,
            attributes: sample["attributes"] as? String,
            nowSeconds: try integer(sample, "nowSeconds") + 4_294_967_296,
            uuidBytes: uuid
        )
        assertSame(wrapped, try string(sample, "ticket"), "ticket.wrapped")

        for (index, count) in [15, 17].enumerated() {
            expectCode(
                "invalid_encoding",
                name: "ticket.uuidLength.\(index)"
            ) {
                _ = try XmlyCrypto.freshTicket(
                    credentials: credentials,
                    nowSeconds: 1_700_000_000,
                    uuidBytes: [UInt8](repeating: 0, count: count)
                )
            }
        }
    }

    func testCredentialsTrimmedDuplicates() throws {
        let expected = try fixtureCredentials()
        // The same credential with surrounding whitespace in one source
        // and bare in another is not a conflict.
        let padded = try Credentials.parse([
            "token": "  \(expected.token) ",
            "deviceId": "  \(expected.deviceId) ",
        ])
        assertSame(padded.token, expected.token, "credentials.trimToken")
        assertSame(
            padded.deviceId, expected.deviceId, "credentials.trimDevice"
        )
        let mixed = try Credentials.parse([
            "token": " \(expected.token)",
            "cookie": expected.cookie,
        ])
        assertSame(mixed.token, expected.token, "credentials.trimMixed")
        let mixedDevice = try Credentials.parse([
            "deviceId": " \(expected.deviceId) ",
            "cookie": expected.cookie,
        ])
        assertSame(
            mixedDevice.deviceId,
            expected.deviceId,
            "credentials.trimMixedDevice"
        )
    }

    func testServerClockExtremeInjectedTime() {
        // Non-finite or out-of-range injected clocks must never trap;
        // now() falls back to the last learned offset (0 if never synced).
        let infinite = ServerClock {
            Date(timeIntervalSince1970: .infinity)
        }
        XCTAssertEqual(infinite.now(), 0, "clock.infinite")
        let huge = ServerClock {
            Date(timeIntervalSince1970: 1e300)
        }
        XCTAssertEqual(huge.now(), 0, "clock.huge")
        let notANumber = ServerClock {
            Date(timeIntervalSince1970: .nan)
        }
        XCTAssertEqual(notANumber.now(), 0, "clock.nan")

        let far = ServerClock { Date.distantFuture }
        XCTAssertTrue(far.now() > 0, "clock.distantFuture")

        let clock = ServerClock {
            Date(timeIntervalSince1970: 1_700_000_000)
        }
        clock.observeMillis(.max)
        XCTAssertEqual(
            clock.now(), 1_700_000_000_000, "clock.observeMaxIgnored"
        )
        XCTAssertFalse(clock.synced, "clock.observeMaxUnsynced")
    }
}
