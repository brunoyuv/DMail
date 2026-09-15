// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
import NIOIMAP
@testable import IMAP

struct MessagePreviewTests {
    @Test func advertisedServerPreviewSurvivesComponentAndMessageDecoding() throws {
        let text = "Server summary 中文 café 😀"
        let component = try #require(Message.Component(.preview(PreviewText(text))))
        let message = Message([.uid(42), component])
        #expect(message.preview == text)
        #expect(message.uid == 42)
        #expect(message.body == nil)
        // Debug descriptions expose the component kind, never preview content.
        #expect(component.description == "preview")
    }
    @Test func lazyNilPreviewIsOptionalAndCannotDropOtherMetadata() throws {
        let component = try #require(Message.Component(.preview(nil)))
        let message = Message([.uid(43), .flags([.seen]), component])
        #expect(message.preview == nil)
        #expect(message.flags.contains(.seen))
        #expect(message.uid == 43)
    }
    @Test func previewRequestsRespectOriginalCapabilityFiltering() {
        let attributes: [IMAP.FetchAttribute] = .standard
        #expect(attributes.filtered([]).contains(.preview(lazy: true)) == false)
        #expect(attributes.filtered([.preview]).contains(.preview(lazy: true)))
    }
    private func text(_ subtype: String, disposition: String? = nil, encoding: String = "8bit") -> BodyStructure {
        .singlepart(.init(kind: .text(.init(mediaSubtype: .init(subtype), lineCount: 1)),
            fields: .init(parameters: ["CHARSET": "utf-8"], id: nil, contentDescription: nil, encoding: .init(encoding), octetCount: 5000),
            extension: disposition.map { .init(digest: nil, dispositionAndLanguage: .init(disposition: .init(kind: .init(rawValue: $0), parameters: [:]))) }))
    }
    @Test func samplePrefersInlinePlainTextAndNeverSelectsTextAttachments() throws {
        let structure = BodyStructure.multipart(.init(parts: [text("plain", disposition: "attachment"),
            text("html"), text("plain")], mediaSubtype: .mixed))
        let sample = try #require(PreviewSample.select(structure))
        #expect(sample.section == .init(part: .init([3])))
        #expect(PreviewSample.select(text("plain", disposition: "attachment")) == nil)
        #expect(PreviewSample.select(text("calendar")) == nil)
    }
    @Test func encodedSamplesAreBoundedAndIncompleteTransferTailsAreDropped() throws {
        let base64 = try #require(PreviewSample.select(text("plain", encoding: "base64")))
        #expect(base64.mime(Data("Y2Fmw6kg5Lit5paH\r\nYQ".utf8))?.suffix(16) == Data("Y2Fmw6kg5Lit5paH".utf8))
        #expect(base64.mime(Data(repeating: 65, count: 2049)) == nil)
        let quoted = try #require(PreviewSample.select(text("plain", encoding: "quoted-printable")))
        #expect(quoted.mime(Data("Hello=E".utf8))?.suffix(5) == Data("Hello".utf8))
    }
    @Test func previewUIDFetchDeadlineDoesNotChangeOrdinaryFetches() {
        let normal = UIDFetchCommand(UIDSet(42), attributes: [.uid])
        let preview = UIDFetchCommand(UIDSet(42), attributes: [.uid], timeout: 1)
        #expect(normal.timeout == 60); #expect(preview.timeout == 1)
    }
    @Test func cappedUTF8AndBase64SamplesRecoverOnlyTheirIncompleteCharacterTail() throws {
        let raw = try #require(PreviewSample.select(text("plain")))
        let prefix = Data(("中文 café 😀 " + String(repeating: "a", count: 2048)).utf8)
        var split = Data(prefix.prefix(2046)); split.append(contentsOf: [0xf0, 0x9f])
        let decoded = raw.candidates(split).compactMap { source -> String? in
            let body = source.dropFirst(raw.header.count)
            return String(data: body, encoding: .utf8)
        }.first
        #expect(decoded?.hasPrefix("中文 café 😀 ") == true)
        #expect(decoded?.contains("�") == false)
        let encoded = try #require(PreviewSample.select(text("plain", encoding: "base64")))
        var bytes = Data("中文 café 😀 ".utf8)
        bytes.append(Data(repeating: 97, count: 1534 - bytes.count)); bytes.append(contentsOf: [0xf0, 0x9f])
        let sample = Data(bytes.base64EncodedString().utf8)
        #expect(sample.count == 2048)
        let text = encoded.candidates(sample).compactMap { source -> String? in
            guard let bytes = Data(base64Encoded: source.dropFirst(encoded.header.count)) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }.first
        #expect(text?.hasPrefix("中文 café 😀 ") == true)
        #expect(raw.candidates(Data([0xff])).count == 1)
    }
}
