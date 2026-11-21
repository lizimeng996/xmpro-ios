import Foundation
import XCTest
@testable import XMPro

final class OrderedJSONTests: XCTestCase {
    private func parse(_ text: String) throws -> XmlyJSONValue {
        try xmlyParseOrderedJSON(Data(text.utf8))
    }

    private func subject() -> XmlyExperienceService {
        XmlyExperienceService(client: XmlyClientService(
            http: FakeHTTPTransport { _, _ in [:] },
            accountContext: nil,
            clock: B1Fixture.clock()
        ))
    }

    private func assertInvalid(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try xmlyParseOrderedJSON(data)
            XCTFail("s4-ordered-invalid", file: file, line: line)
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_json", file: file, line: line)
            XCTAssertEqual(
                error.message, "接口返回无效 JSON", file: file, line: line
            )
        } catch {
            XCTFail("s4-ordered-error-type", file: file, line: line)
        }
    }

    func testObjectPreservesTextKeyOrder() throws {
        let value = try parse(#"{"z":1,"a":{"nickname":"甲","name":"乙"},"m":[]}"#)
        guard case let .object(members) = value,
              let nested = value["a"],
              case let .object(children) = nested else {
            return XCTFail("s4-ordered-object")
        }
        XCTAssertEqual(members.map { $0.0 }, ["z", "a", "m"])
        XCTAssertEqual(children.map { $0.0 }, ["nickname", "name"])
    }

    func testDuplicateKeysReplaceValueWithoutMovingPosition() throws {
        let value = try parse(#"{"name":"旧","nickname":"另一个","name":"新"}"#)
        guard case let .object(members) = value,
              let name = value["name"],
              case let .string(text) = name else {
            return XCTFail("s4-ordered-duplicate")
        }
        XCTAssertEqual(members.map { $0.0 }, ["name", "nickname"])
        XCTAssertEqual(text, "新")
    }

    func testIdenticalDuplicateKeysKeepOnlyLatestIntegerValue() throws {
        let value = try parse(#"{"a":1,"a":2}"#)
        guard case let .object(members) = value,
              let member = value["a"],
              case let .integer(number) = member else {
            return XCTFail("s4-ordered-duplicate-integer")
        }
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.map { $0.0 }, ["a"])
        XCTAssertEqual(number, 2)
    }

    func testCanonicallyEquivalentKeysRemainDistinctAndPreserveOrder() throws {
        let value = try parse(
            #"{"\u00e9":{"name":"甲"},"e\u0301":{"name":"乙"}}"#
        )
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        guard case let .object(members) = value else {
            return XCTFail("s4-ordered-unicode-keys")
        }

        XCTAssertEqual(members.count, 2)
        // Java String 按码元精确比较；断言字节顺序，避免 Swift 规范等价比较。
        XCTAssertEqual(
            members.map { Array($0.0.utf8) },
            [Array(precomposed.utf8), Array(decomposed.utf8)]
        )
        XCTAssertEqual(
            subject().findString(root: value, keys: ["name"]), "甲"
        )

        let first = try XCTUnwrap(value[precomposed])
        let second = try XCTUnwrap(value[decomposed])
        guard case .object = first,
              case .object = second,
              let firstName = first["name"],
              let secondName = second["name"],
              case let .string(firstText) = firstName,
              case let .string(secondText) = secondName else {
            return XCTFail("s4-ordered-unicode-lookup")
        }
        XCTAssertEqual(firstText, "甲")
        XCTAssertEqual(secondText, "乙")
    }

    func testStringEscapesAndUnicodeSurrogatePairs() throws {
        let value = try parse(
            #""\"\\\/\b\f\n\r\t\u0041\u4E2D\uD83D\uDE00""#
        )
        guard case let .string(text) = value else {
            return XCTFail("s4-ordered-string")
        }
        XCTAssertEqual(text, "\"\\/\u{08}\u{0C}\n\r\tA中😀")
        guard case let .string(unescaped) = try parse(#""中文😀""#) else {
            return XCTFail("s4-ordered-utf8")
        }
        XCTAssertEqual(unescaped, "中文😀")
    }

    func testNumberGrammarAcceptsIntegersFractionsAndExponents() throws {
        let value = try parse("[0,-0,123,-42,1.5,-0.25,1e2,1E+2,1e-2]")
        guard case let .array(values) = value else {
            return XCTFail("s4-ordered-numbers")
        }
        let numbers = values.compactMap { value -> Double? in
            switch value {
            case let .integer(number):
                return Double(number)
            case let .number(number):
                return number
            default:
                return nil
            }
        }
        XCTAssertEqual(numbers, [0, -0, 123, -42, 1.5, -0.25, 100, 100, 0.01])
    }

    func testParsedIntegersUseJVMLongIntValueSemantics() throws {
        let positive = try parse(#"{"count":4294967297}"#)
        let positiveCount = try XCTUnwrap(positive["count"])
        guard case let .integer(positiveInteger) = positiveCount else {
            return XCTFail("s4-ordered-positive-long")
        }
        XCTAssertEqual(positiveInteger, 4_294_967_297)
        XCTAssertEqual(xmlyOptInt(positiveCount), 1)
        XCTAssertEqual(
            subject().findCount(root: positive, keys: ["count"]), 1
        )

        let negative = try parse(#"{"count":-4294967297}"#)
        let negativeCount = try XCTUnwrap(negative["count"])
        guard case let .integer(negativeInteger) = negativeCount else {
            return XCTFail("s4-ordered-negative-long")
        }
        XCTAssertEqual(negativeInteger, -4_294_967_297)
        XCTAssertEqual(xmlyOptInt(negativeCount), -1)
    }

    func testIntegerOutsideInt64FallsBackToDoubleAndSaturatesOptInt() throws {
        let value = try parse(#"{"count":9999999999999999999999}"#)
        let count = try XCTUnwrap(value["count"])
        guard case let .number(number) = count else {
            return XCTFail("s4-ordered-long-overflow")
        }
        XCTAssertTrue(number.isFinite)
        XCTAssertEqual(xmlyOptInt(count), 2_147_483_647)
    }

    func testNumberGrammarRejectsMalformedNumbers() {
        for text in [
            "+1", "01", "-01", ".5", "1.", "-", "1e", "1e+",
            "1e-", "--1", "0x1", "NaN", "Infinity", "1 2", "1e400"
        ] {
            assertInvalid(Data(text.utf8))
        }
    }

    func testLiteralsArraysAndWhitespace() throws {
        let value = try parse(" \t\r\n[true,false,null,{},[]]\n")
        guard case let .array(values) = value, values.count == 5,
              case .bool(true) = values[0],
              case .bool(false) = values[1],
              case .null = values[2],
              case .object = values[3],
              case .array = values[4] else {
            return XCTFail("s4-ordered-literals")
        }
    }

    func testNestingLimitAllows512AndRejects513() throws {
        for (opening, closing) in [("[", "]"), (#"{"a":"#, "}")] {
            let accepted = String(repeating: opening, count: 512)
                + "0" + String(repeating: closing, count: 512)
            _ = try parse(accepted)
            let rejected = String(repeating: opening, count: 513)
                + "0" + String(repeating: closing, count: 513)
            assertInvalid(Data(rejected.utf8))
        }
    }

    func testMalformedInputAndInvalidUTF8AreRejected() {
        for text in [
            "{", "[", #"{"a":}"#, #"{"a":1,}"#, "[1,]",
            #"{"a" 1}"#, "{a:1}", "truefalse", "{}[]",
            #""\q""#, #""\u12""#, #""\uZZZZ""#,
            #""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#,
            "\"unterminated", "\"raw\nnewline\"", "\u{000B}{}"
        ] {
            assertInvalid(Data(text.utf8))
        }
        assertInvalid(Data([0x22, 0xC0, 0xAF, 0x22]))
        assertInvalid(Data([0x22, 0xED, 0xA0, 0x80, 0x22]))
    }

    func testEmptyAndWhitespaceOnlyInputAreRejected() {
        assertInvalid(Data())
        assertInvalid(Data(" \t\r\n".utf8))
    }

    func testFindStringUsesCandidateTextOrder() throws {
        let service = subject()
        let first = try parse(#"{"nickname":"昵称","name":"名称"}"#)
        let second = try parse(#"{"name":"名称","nickname":"昵称"}"#)
        XCTAssertEqual(
            service.findString(root: first, keys: ["name", "nickname"]), "昵称"
        )
        XCTAssertEqual(
            service.findString(root: second, keys: ["name", "nickname"]), "名称"
        )
    }

    func testFindStringPreservesChildOrderAndBreadthFirstPriority() throws {
        let service = subject()
        let first = try parse(
            #"{"z":{"name":"左"},"a":{"nickname":"右"}}"#
        )
        let second = try parse(
            #"{"a":{"nickname":"右"},"z":{"name":"左"}}"#
        )
        XCTAssertEqual(
            service.findString(root: first, keys: ["name", "nickname"]), "左"
        )
        XCTAssertEqual(
            service.findString(root: second, keys: ["name", "nickname"]), "右"
        )
        let breadth = try parse(
            #"{"z":{"deep":{"name":"深层"}},"a":{"name":"浅层"}}"#
        )
        XCTAssertEqual(service.findString(root: breadth, keys: ["name"]), "浅层")
    }

    func testFindStringSkipsBlankAndNonStringValuesAndPreservesArrayOrder() throws {
        let value = try parse(
            #"{"name":true,"nickname":" \n\t","children":[{"name":"第一"},{"name":"第二"}]}"#
        )
        XCTAssertEqual(
            subject().findString(root: value, keys: ["name", "nickname"]), "第一"
        )
    }

    func testFindStringHonors3000NodeBudget() {
        let service = subject()
        let empty = XmlyJSONValue.object([])
        let found = XmlyJSONValue.object([("name", .string("边界"))])
        let inside = XmlyJSONValue.array(
            Array(repeating: empty, count: 2_998) + [found]
        )
        let outside = XmlyJSONValue.array(
            Array(repeating: empty, count: 2_999) + [found]
        )
        XCTAssertEqual(service.findString(root: inside, keys: ["name"]), "边界")
        XCTAssertNil(service.findString(root: outside, keys: ["name"]))
    }

    func testOptIntHandlesNumbersStringsAndBooleans() {
        XCTAssertEqual(xmlyOptInt(NSNumber(value: 1.5)), 1)
        XCTAssertEqual(xmlyOptInt("1" as Any), 1)
        XCTAssertEqual(xmlyOptInt("1.5" as Any), 1)
        XCTAssertEqual(xmlyOptInt("1e1" as Any), 10)
        XCTAssertNil(xmlyOptInt(NSNumber(value: true)))
        XCTAssertNil(xmlyOptInt("invalid" as Any))
        XCTAssertNil(xmlyOptInt(NSNull()))

        // JVM 32 位语义：整数取低 32 位（截断），浮点／字符串越界饱和。
        XCTAssertEqual(xmlyOptInt(NSNumber(value: 4_294_967_297 as Int64)), 1)
        XCTAssertEqual(xmlyOptInt(NSNumber(value: 4_294_967_297.0)), 2_147_483_647)
        XCTAssertEqual(xmlyOptInt(NSNumber(value: -4_294_967_297.0)), -2_147_483_648)
        XCTAssertEqual(xmlyOptInt(NSNumber(value: Double.nan)), 0)
        XCTAssertEqual(xmlyOptInt("4294967297" as Any), 2_147_483_647)
        XCTAssertEqual(xmlyOptInt(XmlyJSONValue.number(4_294_967_297)), 2_147_483_647)
        XCTAssertEqual(xmlyOptInt(XmlyJSONValue.number(-4_294_967_297)), -2_147_483_648)

        XCTAssertEqual(xmlyOptInt(XmlyJSONValue.number(1.5)), 1)
        XCTAssertEqual(xmlyOptInt(XmlyJSONValue.number(-1.5)), -1)
        XCTAssertEqual(xmlyOptInt(XmlyJSONValue.string("1.5")), 1)
        XCTAssertNil(xmlyOptInt(XmlyJSONValue.bool(true)))
        XCTAssertNil(xmlyOptInt(XmlyJSONValue.null))
    }

    func testFindCountTruncatesAndContinuesAfterInvalidValues() throws {
        let service = subject()
        let fraction = try parse(#"{"count":1.5,"total":7}"#)
        XCTAssertEqual(service.findCount(root: fraction, keys: ["count", "total"]), 1)

        let text = try parse(#"{"count":"1.5"}"#)
        XCTAssertEqual(service.findCount(root: text, keys: ["count"]), 1)

        let invalid = try parse(
            #"{"count":true,"total":-2,"child":{"count":"3.8"}}"#
        )
        XCTAssertEqual(
            service.findCount(root: invalid, keys: ["count", "total"]), 3
        )
    }

    func testOrderedRequestBindsCredentialsHeadersAndCollectorLimit() async throws {
        let fake = FakeHTTPTransport(
            rawDataHandler: { _, _ in Data(#"{"z":1,"a":2}"#.utf8) }
        ) { _, _ in
            XCTFail("s4-ordered-dictionary-path")
            return [:]
        }
        let anonymous = XmlyClientService(http: fake, accountContext: nil)
        await b1ExpectError("login_required", "s4-ordered-login", definitive: true) {
            _ = try await anonymous.requestOrdered(
                method: "GET", origin: XmlyOrigin.mobile.rawValue, path: "/fixture"
            )
        }
        XCTAssertTrue(fake.calls.isEmpty)

        let client = XmlyClientService(
            http: fake, accountContext: try B1Fixture.context()
        )
        let value = try await client.requestOrdered(
            method: "GET",
            origin: XmlyOrigin.collector.rawValue,
            path: "/fixture",
            query: ["key": "value"],
            readOnly: false,
            signed: true,
            headers: ["Accept": "application/json"]
        )
        guard case let .object(members) = value else {
            return XCTFail("s4-ordered-request-object")
        }
        XCTAssertEqual(members.map { $0.0 }, ["z", "a"])
        let call = try XCTUnwrap(fake.calls.last)
        b1Check(
            call.method == "GET"
                && call.authenticated && call.signed && !call.readOnly
                && call.query == ["key": "value"]
                && call.responseLimit == 8 * 1024 * 1024
                && call.headers["User-Agent"] == ProtocolConfig.collectorUserAgent
                && call.headers["Accept"] == "application/json",
            "s4-ordered-request-binding"
        )

        _ = try await anonymous.requestOrdered(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/fixture",
            account: false
        )
        b1Check(
            fake.calls.last?.authenticated == false
                && fake.calls.last?.responseLimit == nil,
            "s4-ordered-anonymous"
        )
    }

    func testOrderedRequestRejectsNonObjectRoot() async throws {
        let fake = FakeHTTPTransport(
            rawDataHandler: { _, _ in Data("[]".utf8) }
        ) { _, _ in [:] }
        let client = XmlyClientService(http: fake, accountContext: nil)
        do {
            _ = try await client.requestOrdered(
                method: "GET",
                origin: XmlyOrigin.mobile.rawValue,
                path: "/fixture",
                account: false
            )
            XCTFail("s4-ordered-root")
        } catch let error as XmlyError {
            XCTAssertEqual(error.code, "invalid_json")
            XCTAssertEqual(error.message, "接口返回无效 JSON")
        }
    }

    func testOrderedRequestObservesNumericTimestamp() async throws {
        let timestamp = B1Fixture.now + 30_000
        let actualClock = B1Fixture.clock()
        let expectedClock = B1Fixture.clock()
        expectedClock.observePayload(timestamp: NSNumber(value: timestamp))
        let fake = FakeHTTPTransport(
            rawDataHandler: { _, _ in
                Data("{\"timestamp\":\(timestamp),\"data\":{}}".utf8)
            }
        ) { _, _ in [:] }
        let client = XmlyClientService(
            http: fake, accountContext: nil, clock: actualClock
        )
        _ = try await client.requestOrdered(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/fixture",
            account: false
        )
        XCTAssertEqual(actualClock.now(), expectedClock.now())
    }

    func testOrderedRequestObservesStringTimestamp() async throws {
        let timestamp = B1Fixture.now + 45_000
        let actualClock = B1Fixture.clock()
        let expectedClock = B1Fixture.clock()
        expectedClock.observePayload(timestamp: String(timestamp))
        let fake = FakeHTTPTransport(
            rawDataHandler: { _, _ in
                Data("{\"timestamp\":\"\(timestamp)\",\"data\":{}}".utf8)
            }
        ) { _, _ in [:] }
        let client = XmlyClientService(
            http: fake, accountContext: nil, clock: actualClock
        )
        _ = try await client.requestOrdered(
            method: "GET",
            origin: XmlyOrigin.mobile.rawValue,
            path: "/fixture",
            account: false
        )
        XCTAssertEqual(actualClock.now(), expectedClock.now())
    }
}
