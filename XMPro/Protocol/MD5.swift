// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// RFC 1321 MD5. This implements a legacy protocol primitive, not password hashing.
enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]

    private static let constants: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
    ]

    private static func rotateLeft(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }

    static func digest(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        let bitCount = UInt64(truncatingIfNeeded: input.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        for index in 0..<8 {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> (index * 8)))
        }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xefcdab89
        var c0: UInt32 = 0x98badcfe
        var d0: UInt32 = 0x10325476

        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = UInt32(bytes[start])
                    | (UInt32(bytes[start + 1]) << 8)
                    | (UInt32(bytes[start + 2]) << 16)
                    | (UInt32(bytes[start + 3]) << 24)
            }

            var a = a0
            var b = b0
            var c = c0
            var d = d0

            for index in 0..<64 {
                let f: UInt32
                let g: Int
                switch index {
                case 0..<16:
                    f = (b & c) | ((~b) & d)
                    g = index
                case 16..<32:
                    f = (d & b) | ((~d) & c)
                    g = (5 * index + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * index + 5) % 16
                default:
                    f = c ^ (b | (~d))
                    g = (7 * index) % 16
                }

                let oldD = d
                d = c
                c = b
                b = b &+ rotateLeft(
                    a &+ f &+ constants[index] &+ words[g],
                    by: shifts[index]
                )
                a = oldD
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var result: [UInt8] = []
        result.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for index in 0..<4 {
                result.append(UInt8(truncatingIfNeeded: word >> (index * 8)))
            }
        }
        return result
    }

    static func hex(_ input: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(32)
        for byte in digest(input) {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func hex(_ string: String) -> String {
        hex(Array(string.utf8))
    }
}
