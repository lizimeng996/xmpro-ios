import Foundation

enum XmlyJSONValue: Sendable {
    case object([(String, XmlyJSONValue)])
    case array([XmlyJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    subscript(key: String) -> XmlyJSONValue? {
        guard case let .object(members) = self else { return nil }
        // Java String 不做规范等价比较；合法 Unicode 键按 UTF-8 字节精确匹配。
        return members.first(where: { $0.0.utf8.elementsEqual(key.utf8) })?.1
    }
}

// Foundation 路径：按 Kotlin optInt 的 JVM 32 位整数语义转换。
// NSNumber 整数取低 32 位（int32Value 截断，与 Java Number.intValue()
// 一致）；浮点与字符串经 Double 后按 32 位饱和截断。
func xmlyOptInt(_ value: Any?) -> Int? {
    if let number = value as? NSNumber {
        guard !xmlyIsBoolean(number) else { return nil }
        if CFNumberIsFloatType(number) {
            return xmlyTruncatedInt(number.doubleValue)
        }
        return Int(number.int32Value)
    }
    if let text = value as? String {
        return xmlyOptIntString(text)
    }
    return nil
}

func xmlyOptInt(_ value: XmlyJSONValue) -> Int? {
    switch value {
    case let .integer(number):
        // JVM Long.intValue()：取低 32 位，与浮点的饱和截断区分。
        return Int(Int32(truncatingIfNeeded: number))
    case let .number(number):
        return xmlyTruncatedInt(number)
    case let .string(text):
        return xmlyOptIntString(text)
    default:
        return nil
    }
}

private func xmlyOptIntString(_ text: String) -> Int? {
    if let integer = Int32(text) { return Int(integer) }
    guard let number = B1JSON.jvmDouble(text) else { return nil }
    return xmlyTruncatedInt(number)
}

private func xmlyTruncatedInt(_ number: Double) -> Int {
    // JVM (int)double：NaN 返回 0，越界饱和到 32 位边界，界内向零截断。
    if number.isNaN { return 0 }
    if number >= Double(Int32.max) + 1 { return Int(Int32.max) }
    if number < Double(Int32.min) { return Int(Int32.min) }
    return Int(number.rounded(.towardZero))
}

func xmlyParseOrderedJSON(_ data: Data) throws -> XmlyJSONValue {
    var parser = XmlyOrderedJSONParser(bytes: Array(data))
    return try parser.parse()
}

private struct XmlyOrderedJSONParser {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private var invalid: XmlyError {
        .failure(code: .invalidJSON, message: "接口返回无效 JSON")
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    mutating func parse() throws -> XmlyJSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw invalid }
        return value
    }

    private mutating func skipWhitespace() {
        while let byte = current {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            default:
                return
            }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func require(_ byte: UInt8) throws {
        guard consume(byte) else { throw invalid }
    }

    // depth 表示当前值外侧的对象／数组层数；根容器为第 1 层。
    private mutating func parseValue(depth: Int) throws -> XmlyJSONValue {
        skipWhitespace()
        guard let byte = current else { throw invalid }
        switch byte {
        case 0x7B:
            guard depth < 512 else { throw invalid }
            return try parseObject(depth: depth + 1)
        case 0x5B:
            guard depth < 512 else { throw invalid }
            return try parseArray(depth: depth + 1)
        case 0x22:
            return .string(try parseString())
        case 0x74:
            try literal("true")
            return .bool(true)
        case 0x66:
            try literal("false")
            return .bool(false)
        case 0x6E:
            try literal("null")
            return .null
        case 0x2D, 0x30...0x39:
            return try parseNumber()
        default:
            throw invalid
        }
    }

    private mutating func parseObject(depth: Int) throws -> XmlyJSONValue {
        try require(0x7B)
        skipWhitespace()
        var members: [(String, XmlyJSONValue)] = []
        var positions: [[UInt8]: Int] = [:]
        if consume(0x7D) { return .object(members) }

        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try require(0x3A)
            let value = try parseValue(depth: depth)

            // AOSP LinkedHashMap：同名键更新值，保留首次插入的位置。
            // 按 UTF-8 字节区分规范等价但码元不同的键，对齐 Java String。
            let keyBytes = Array(key.utf8)
            if let position = positions[keyBytes] {
                members[position].1 = value
            } else {
                positions[keyBytes] = members.count
                members.append((key, value))
            }

            skipWhitespace()
            if consume(0x7D) { return .object(members) }
            try require(0x2C)
        }
    }

    private mutating func parseArray(depth: Int) throws -> XmlyJSONValue {
        try require(0x5B)
        skipWhitespace()
        var values: [XmlyJSONValue] = []
        if consume(0x5D) { return .array(values) }

        while true {
            values.append(try parseValue(depth: depth))
            skipWhitespace()
            if consume(0x5D) { return .array(values) }
            try require(0x2C)
        }
    }

    private mutating func parseString() throws -> String {
        try require(0x22)
        var decoded: [UInt8] = []

        while let byte = current {
            index += 1
            if byte == 0x22 {
                guard let string = String(bytes: decoded, encoding: .utf8) else {
                    throw invalid
                }
                return string
            }
            guard byte >= 0x20 else { throw invalid }
            if byte != 0x5C {
                decoded.append(byte)
                continue
            }

            guard let escape = current else { throw invalid }
            index += 1
            switch escape {
            case 0x22, 0x5C, 0x2F:
                decoded.append(escape)
            case 0x62:
                decoded.append(0x08)
            case 0x66:
                decoded.append(0x0C)
            case 0x6E:
                decoded.append(0x0A)
            case 0x72:
                decoded.append(0x0D)
            case 0x74:
                decoded.append(0x09)
            case 0x75:
                let first = try hexQuad()
                let scalarValue: UInt32
                if (0xD800...0xDBFF).contains(first) {
                    try require(0x5C)
                    try require(0x75)
                    let second = try hexQuad()
                    guard (0xDC00...0xDFFF).contains(second) else {
                        throw invalid
                    }
                    scalarValue = 0x10000
                        + ((first - 0xD800) << 10)
                        + (second - 0xDC00)
                } else {
                    guard !(0xDC00...0xDFFF).contains(first) else {
                        throw invalid
                    }
                    scalarValue = first
                }
                guard let scalar = UnicodeScalar(scalarValue) else {
                    throw invalid
                }
                decoded.append(contentsOf: String(scalar).utf8)
            default:
                throw invalid
            }
        }
        throw invalid
    }

    private mutating func hexQuad() throws -> UInt32 {
        var result: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else { throw invalid }
            let digit: UInt32
            switch byte {
            case 0x30...0x39:
                digit = UInt32(byte - 0x30)
            case 0x41...0x46:
                digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66:
                digit = UInt32(byte - 0x61 + 10)
            default:
                throw invalid
            }
            result = (result << 4) | digit
            index += 1
        }
        return result
    }

    private mutating func literal(_ text: String) throws {
        for byte in text.utf8 {
            try require(byte)
        }
    }

    private var isDigit: Bool {
        guard let byte = current else { return false }
        return (0x30...0x39).contains(byte)
    }

    private mutating func parseNumber() throws -> XmlyJSONValue {
        let start = index
        var isInteger = true
        _ = consume(0x2D)

        if consume(0x30) {
            guard !isDigit else { throw invalid }
        } else {
            guard let byte = current, (0x31...0x39).contains(byte) else {
                throw invalid
            }
            index += 1
            while isDigit { index += 1 }
        }

        if consume(0x2E) {
            isInteger = false
            guard isDigit else { throw invalid }
            while isDigit { index += 1 }
        }

        if current == 0x65 || current == 0x45 {
            isInteger = false
            index += 1
            if current == 0x2B || current == 0x2D { index += 1 }
            guard isDigit else { throw invalid }
            while isDigit { index += 1 }
        }

        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        // 对齐 Android org.json：整数词形优先保留 Long，越界再尝试 Double。
        if isInteger, let integer = Int64(text) {
            return .integer(integer)
        }
        guard let number = Double(text), number.isFinite else {
            throw invalid
        }
        return .number(number)
    }
}
