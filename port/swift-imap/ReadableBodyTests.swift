import Foundation
import Testing
import NIOIMAPCore
@testable import IMAP

struct ReadableBodyTests {
    private func part(_ kind: BodyStructure.Singlepart.Kind, bytes: Int, disposition: String? = nil, id: String? = nil) -> BodyStructure {
        .singlepart(.init(kind: kind, fields: .init(parameters: [:], id: id, contentDescription: nil, encoding: .init("base64"), octetCount: bytes),
            extension: disposition.map { .init(digest: nil, dispositionAndLanguage: .init(disposition: .init(kind: .init(rawValue: $0), parameters: [:]))) }))
    }
    private var text: BodyStructure.Singlepart.Kind { .text(.init(mediaSubtype: .init("html"), lineCount: 1)) }
    @Test func largePDFAttachmentNeverBecomesABodyDownload() throws {
        let tree = BodyStructure.multipart(.init(parts: [
            .multipart(.init(parts: [part(text, bytes: 128)], mediaSubtype: .alternative)),
            part(.basic(.init(topLevel: .application, sub: .init("pdf"))), bytes: 3327488, disposition: "ATTACHMENT")
        ], mediaSubtype: .mixed))
        let plan = try ReadablePlan(tree)
        #expect(plan.parts.map(\.section) == [SectionSpecifier(part: .init([1,1]))])
        #expect(plan.hasAttachments)
        #expect(!plan.partial)
        #expect(plan.attachments.count == 1)
        #expect(plan.attachments.first?.id == "2")
        #expect(plan.attachments.first?.contentType == "application/pdf")
        #expect(plan.attachments.first?.encodedSize == 3327488)
    }
    @Test func inlineCIDImagesLoadButTextAttachmentsDoNot() throws {
        let tree = BodyStructure.multipart(.init(parts: [part(text, bytes: 100),
            part(.basic(.init(topLevel: .image, sub: .init("png"))), bytes: 50, id: "image@example.test"),
            part(text, bytes: 30, disposition: "attachment")], mediaSubtype: .related))
        let plan = try ReadablePlan(tree)
        #expect(plan.parts.count == 2)
        #expect(plan.hasAttachments)
    }
    @Test func attachedMultipartIsNotFlattenedIntoBody() throws {
        let tree = BodyStructure.multipart(.init(parts: [part(text, bytes: 100)], mediaSubtype: .mixed,
            extension: .init(parameters: [:], dispositionAndLanguage: .init(disposition: .init(kind: .init(rawValue: "attachment"), parameters: [:])))))
        #expect(try ReadablePlan(tree).parts.isEmpty)
        #expect(try ReadablePlan(tree).hasAttachments)
    }
    @Test func contentLocationAndAttachedCIDImagesRemainReadable() throws {
        let image = BodyStructure.singlepart(.init(kind: .basic(.init(topLevel: .image, sub: .init("png"))),
            fields: .init(parameters: [:], id: nil, contentDescription: nil, encoding: .init("base64"), octetCount: 100),
            extension: .init(digest: nil, dispositionAndLanguage: .init(disposition: nil,
                language: .init(languages: [], location: .init(location: "image1", extensions: []))))))
        let tree = BodyStructure.multipart(.init(parts: [image,
            part(.basic(.init(topLevel: .image, sub: .init("png"))), bytes: 50, disposition: "attachment", id: "image@example.test")], mediaSubtype: .related))
        let plan = try ReadablePlan(tree)
        #expect(plan.parts.count == 2)
        #expect(plan.hasAttachments)
    }
    @Test func excessiveReadablePartsAndSizesAreExplicitlyPartial() throws {
        let tree = BodyStructure.multipart(.init(parts: [part(text, bytes: 4*1024*1024+1),part(text, bytes: 100)], mediaSubtype: .mixed))
        let plan = try ReadablePlan(tree)
        #expect(plan.partial)
        #expect(plan.parts.map(\.section) == [SectionSpecifier(part: .init([2]))])
    }
    @Test func deepStructuresFailBeforeUnboundedRecursion() throws {
        var tree = part(text, bytes: 1)
        for _ in 0..<40 { tree = .multipart(.init(parts: [tree], mediaSubtype: .mixed)) }
        #expect(throws: (any Error).self) { try ReadablePlan(tree) }
    }
    @Test func sectionPartsKeepReferencesAndRawBytesSeparate() throws {
        let header = SectionSpecifier.headerFields(["References"])
        let section = SectionSpecifier(part: .init([1]))
        let value = Message([.bodyPart(header, Data("References: <root@example.test>\r\n\r\n".utf8)),
            .bodyPart(section, Data("<p>Raw HTML without MIME headers</p>".utf8))])
        #expect(value.references == ["root@example.test"])
        #expect(value.body == nil)
        #expect(value.bodySections[section] == Data("<p>Raw HTML without MIME headers</p>".utf8))
    }
}
