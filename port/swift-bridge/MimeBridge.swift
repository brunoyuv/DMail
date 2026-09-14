// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. https://mozilla.org/MPL/2.0/
import Foundation
import MIME

// Wire representations of upstream values; parsing and serialization stay in MIME.
private struct MimeHeaderValue: Encodable {
    let name: String
    let value: String
}

private struct MimePartValue: Encodable {
    let contentType: String
    let transferEncoding: String?
    let disposition: String?
    let contentId: String?
    let encodedPayloadBase64: String
    let parts: [MimePartValue]

    init(_ part: Part, depth: Int, remaining: inout Int) throws {
        guard depth <= 32, remaining > 0 else { throw BridgeError.limit }
        remaining -= 1
        contentType = part.contentType.rawValue
        transferEncoding = part.contentTransferEncoding?.rawValue
        disposition = part.contentDisposition?.description
        contentId = part.contentID?.description
        encodedPayloadBase64 = part.data.base64EncodedString()
        parts = try part.contentType.isMultipart
            ? part.parts.map { try MimePartValue($0, depth: depth + 1, remaining: &remaining) } : []
    }
}

private struct MimeBodyValue: Encodable {
    let headers: [MimeHeaderValue]
    let part: MimePartValue
    let rawValueBase64: String
    let isEmpty: Bool

    init(_ body: Body) throws {
        var remaining = 4096
        part = try MimePartValue(body.part, depth: 0, remaining: &remaining)
        headers = body.headers.map { MimeHeaderValue(name: $0.name.rawValue, value: $0.value) }
        rawValueBase64 = body.rawValue.base64EncodedString()
        isEmpty = body.isEmpty
    }
}

private enum BridgeError: Error { case input, limit }
private struct MimeReply: Encodable {
    var value: String? = nil
    var body: MimeBodyValue? = nil
    var error: String? = nil
}

@_cdecl("thunderbird_mime_request")
public func thunderbirdMimeRequest(_ operation: Int32, _ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    var reply = MimeReply()
    do {
        guard let input, let value = String(validatingCString: input) else { throw BridgeError.input }
        switch operation {
        case 0: reply.value = try value.headerDecoded()
        case 1: reply.value = try value.headerEncoded()
        case 2:
            // Upstream Body expects an ASCII transfer representation, not decoded Unicode text.
            guard value.utf8.allSatisfy({ $0 < 128 }) else { throw BridgeError.input }
            reply.body = try MimeBodyValue(Body(value))
        default: throw BridgeError.input
        }
    } catch BridgeError.limit {
        reply.error = "MIME_LIMIT"
    } catch BridgeError.input {
        reply.error = "MIME_INPUT"
    } catch {
        // Don't expose message contents through upstream error descriptions.
        reply.error = "MIME_INVALID"
    }
    guard let data = try? JSONEncoder().encode(reply) else { return nil }
    let result = UnsafeMutablePointer<CChar>.allocate(capacity: data.count + 1)
    for (index, byte) in data.enumerated() { result[index] = CChar(bitPattern: byte) }
    result[data.count] = 0
    return result
}

@_cdecl("thunderbird_string_free")
public func thunderbirdStringFree(_ value: UnsafeMutablePointer<CChar>?) {
    value?.deallocate()
}
