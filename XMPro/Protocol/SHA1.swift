// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// SHA-1 for compatibility with the existing login protocol.
enum SHA1 {
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
        for index in stride(from: 7, through: 0, by: -1) {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> (index * 8)))
        }

        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xefcdab89
        var h2: UInt32 = 0x98badcfe
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xc3d2e1f0

        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 80)
            for index in 0..<16 {
                let start = offset + index * 4
                words[index] = (UInt32(bytes[start]) << 24)
                    | (UInt32(bytes[start + 1]) << 16)
                    | (UInt32(bytes[start + 2]) << 8)
                    | UInt32(bytes[start + 3])
            }
            for index in 16..<80 {
                words[index] = rotateLeft(
                    words[index - 3] ^ words[index - 8]
                        ^ words[index - 14] ^ words[index - 16],
                    by: 1
                )
            }

            var a = h0
            var b = h1
            var c = h2
            var d = h3
            var e = h4

            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5a827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ed9eba1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8f1bbcdc
                default:
                    f = b ^ c ^ d
                    k = 0xca62c1d6
                }
                let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = rotateLeft(b, by: 30)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var result: [UInt8] = []
        result.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            for index in stride(from: 3, through: 0, by: -1) {
                result.append(UInt8(truncatingIfNeeded: word >> (index * 8)))
            }
        }
        return result
    }

    static func hex(_ input: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(40)
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
