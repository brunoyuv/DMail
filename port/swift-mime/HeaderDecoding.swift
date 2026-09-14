// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CoreFoundation
import Foundation

/// RFC 2047 words can occur among plain text and use different encodings in one
/// header. Decode each word once; never reinterpret already decoded Unicode.
enum HeaderDecoding {
    private static let words = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)

    static func decode(_ header: String) -> String {
        let matches = words.matches(in: header, range: NSRange(header.startIndex..., in: header))
        var result = ""
        var position = header.startIndex
        var previousDecoded = false
        for match in matches {
            guard let range = Range(match.range, in: header),
                let charsetRange = Range(match.range(at: 1), in: header),
                let encodingRange = Range(match.range(at: 2), in: header),
                let contentRange = Range(match.range(at: 3), in: header)
            else { continue }
            let decoded = decodeWord(charset: String(header[charsetRange]),
                transfer: String(header[encodingRange]), content: String(header[contentRange]))
            let between = header[position..<range.lowerBound]
            // RFC 2047 section 6.2: ignore linear whitespace only when it
            // separates two encoded words. Keep spacing beside ordinary text.
            if !(previousDecoded && decoded != nil && between.allSatisfy({ " \t\r\n".contains($0) })) {
                result += between
            }
            // Bad bytes or an unknown charset must not discard the subject or
            // sender name: the original IMAP callers use try? on this method.
            result += decoded ?? String(header[range])
            previousDecoded = decoded != nil
            position = range.upperBound
        }
        result += header[position...]
        return result
    }

    private static func decodeWord(charset: String, transfer: String, content: String) -> String? {
        guard let encoding = encoding(charset) else { return nil }
        let bytes: Data?
        if transfer.uppercased() == "B" {
            bytes = Data(base64Encoded: content)
        } else {
            bytes = qBytes(content)
        }
        guard let bytes else { return nil }
        return String(data: bytes, encoding: encoding)
    }

    private static func encoding(_ charset: String) -> String.Encoding? {
        if charset.uppercased() == "UTF8" { return .utf8 }
        let name = CFStringCreateWithCString(nil, charset, CFStringBuiltInEncodings.UTF8.rawValue)
        let value = CFStringConvertIANACharSetNameToEncoding(name)
        guard value != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
    }

    private static func qBytes(_ content: String) -> Data? {
        let source = Array(content.utf8)
        var result = Data()
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 61 { // =HH; retain upstream tolerance for soft-wrapped Q words.
                if index + 1 < source.count, source[index + 1] == 10 { index += 2; continue }
                if index + 2 < source.count, source[index + 1] == 13, source[index + 2] == 10 {
                    index += 3; continue
                }
                guard index + 2 < source.count,
                    let high = hex(source[index + 1]), let low = hex(source[index + 2]) else { return nil }
                result.append(high * 16 + low)
                index += 3
            } else {
                guard (33...126).contains(byte) else { return nil }
                result.append(byte == 95 ? 32 : byte) // Q underscores represent spaces, only in headers.
                index += 1
            }
        }
        return result
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
