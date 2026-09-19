import Foundation
import Testing
import NIOIMAPCore
import MIME
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
        let tree = BodyStructure.multipart(.init(parts: [part(text, bytes: 100), image,
            part(.basic(.init(topLevel: .image, sub: .init("png"))), bytes: 50, disposition: "attachment", id: "image@example.test")], mediaSubtype: .related))
        let plan = try ReadablePlan(tree)
        #expect(plan.parts.count == 3)
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

struct AttachmentOnlyReadableTests {
    private func leaf(_ type: BodyStructure.Singlepart.Kind, bytes: Int = 64, id: String? = nil,
                      disposition: String? = nil) -> BodyStructure {
        .singlepart(.init(kind: type, fields: .init(parameters: [:], id: id, contentDescription: nil,
            encoding: .init("base64"), octetCount: bytes),
            extension: disposition.map { .init(digest: nil, dispositionAndLanguage: .init(
                disposition: .init(kind: .init(rawValue: $0), parameters: [:]))) }))
    }
    private var pdf: BodyStructure.Singlepart.Kind { .basic(.init(topLevel: .application, sub: .init("pdf"))) }
    private var image: BodyStructure.Singlepart.Kind { .basic(.init(topLevel: .image, sub: .init("png"))) }
    @Test func standaloneAndMultipartPDFKeepMetadataWithoutFetchingPayload() throws {
        for tree in [leaf(pdf, disposition: "attachment"),
                     .multipart(.init(parts: [leaf(pdf, disposition: "attachment")], mediaSubtype: .mixed))] {
            let plan = try ReadablePlan(tree)
            #expect(plan.parts.isEmpty)
            #expect(plan.hasAttachments)
            #expect(plan.attachments.count == 1)
            #expect(plan.attachments[0].id == "1")
            #expect(plan.attachments[0].contentType == "application/pdf")
            #expect(!plan.partial)
            #expect(try plan.assemble([:]) == nil)
        }
    }
    @Test func emptyTextWithPDFKeepsAValidEmptyTextSection() throws {
        let plan = try ReadablePlan(.multipart(.init(parts: [
            leaf(.text(.init(mediaSubtype: .init("plain"), lineCount: 0)), bytes: 0),
            leaf(pdf, disposition: "attachment")], mediaSubtype: .mixed)))
        #expect(plan.parts.count == 1)
        #expect(plan.parts[0].octets == 0)
        #expect(plan.attachments.map(\.id) == ["2"])
        let body = try #require(try plan.assemble([plan.parts[0].section: Data("Content-Type: text/plain\r\n\r\n".utf8)]))
        let children = try body.part.parts
        #expect(children[0].data.isEmpty)
        #expect(children[0].contentType.subtype == "plain")
        #expect(!plan.partial)
    }
    @Test func standaloneAndMultipartCIDOnlyImagesAreOnDemandAttachments() throws {
        for tree in [leaf(image, id: "picture@example.test"),
                     leaf(image, id: "picture@example.test", disposition: "attachment"),
                     leaf(image, bytes: 8 * 1024 * 1024, id: "picture@example.test"),
                     .multipart(.init(parts: [leaf(image, id: "picture@example.test")], mediaSubtype: .mixed)),
                     .multipart(.init(parts: [leaf(image, id: "picture@example.test")], mediaSubtype: .init("related")))] {
            let plan = try ReadablePlan(tree)
            #expect(plan.parts.isEmpty)
            #expect(plan.hasAttachments)
            #expect(plan.attachments.map(\.id) == ["1"])
            #expect(plan.attachments.first?.contentType == "image/png")
            #expect(!plan.partial)
            #expect(try plan.assemble([:]) == nil)
        }
    }
    @Test func oversizedTextIsNotReclassifiedAsAnAttachmentOnlyMessage() throws {
        let plan = try ReadablePlan(.multipart(.init(parts: [
            leaf(.text(.init(mediaSubtype: .init("html"), lineCount: 1)), bytes: 4 * 1024 * 1024 + 1),
            leaf(image, id: "picture@example.test")], mediaSubtype: .init("related"))))
        #expect(plan.partial)
        #expect(plan.parts.map(\.section) == [SectionSpecifier(part: .init([2]))])
        #expect(plan.attachments.isEmpty)
        let body = try #require(try plan.assemble([plan.parts[0].section: Data("Content-Type: image/png\r\n\r\nbytes".utf8)]))
        #expect(try body.part.parts[0].contentType == .application("x-dmail-omitted"))
    }
    @Test func zeroByteTextStubsKeepCIDImagesAvailableAsAttachments() throws {
        for subtype in ["plain", "html"] {
            let plan = try ReadablePlan(.multipart(.init(parts: [
                leaf(.text(.init(mediaSubtype: .init(subtype), lineCount: 0)), bytes: 0),
                leaf(image, bytes: 8 * 1024 * 1024, id: "picture@example.test")], mediaSubtype: .mixed)))
            #expect(!plan.partial)
            #expect(plan.hasAttachments)
            #expect(plan.parts.map(\.section) == [SectionSpecifier(part: .init([1]))])
            #expect(plan.attachments.map(\.id) == ["2"])
            let body = try #require(try plan.assemble([plan.parts[0].section: Data("Content-Type: text/\(subtype)\r\n\r\n".utf8)]))
            #expect(try body.part.parts[0].data.isEmpty)
        }
    }
    @Test func explicitRelatedEmptyMultipartRootKeepsItsIdentityMetadata() throws {
        let plan = try ReadablePlan(.multipart(.init(parts: [leaf(image, id: "picture@example.test"),
            .multipart(.init(parts: [leaf(.text(.init(mediaSubtype: .init("plain"), lineCount: 0)), bytes: 0)], mediaSubtype: .alternative))],
            mediaSubtype: .init("related"), extension: .init(parameters: ["start": "<root@example.test>"], dispositionAndLanguage: nil))))
        let header = SectionSpecifier(part: .init([2]), kind: .MIMEHeader)
        #expect(plan.metadataSections == [header])
        #expect(plan.parts.map(\.section) == [SectionSpecifier(part: .init([2, 1]))])
        #expect(plan.attachments.map(\.id) == ["1"])
        #expect(!plan.partial)
        let body = try #require(try plan.assemble([plan.parts[0].section: Data("Content-Type: text/plain\r\n\r\n".utf8)],
            metadata: [header: Data("Content-Type: multipart/alternative; boundary=synthetic\r\nContent-ID: <root@example.test>\r\n\r\n".utf8)]))
        #expect(try body.part.parts[1].contentID?.description == "<root@example.test>")
    }
    @Test func manyCIDAttachmentsCannotCrowdOutAnEmptyTextStubAndFailTheMessage() throws {
        let images = (0..<25).map { leaf(image, id: "picture\($0)@example.test") }
        let stub = leaf(.text(.init(mediaSubtype: .init("plain"), lineCount: 0)), bytes: 0)
        let plan = try ReadablePlan(.multipart(.init(parts: images + [stub], mediaSubtype: .mixed)))
        #expect(plan.hasAttachments)
        #expect(plan.attachments.count == 25)
        #expect(plan.parts.isEmpty)
        #expect(!plan.partial)
        #expect(try plan.assemble([:]) == nil)
    }
}

struct ReadableTopologyTests {
    private func leaf(_ type: BodyStructure.Singlepart.Kind, id: String? = nil, bytes: Int = 64, disposition: String? = nil) -> BodyStructure {
        .singlepart(.init(kind: type, fields: .init(parameters: [:], id: id, contentDescription: nil, encoding: .init("8bit"), octetCount: bytes),
            extension: disposition.map { .init(digest: nil, dispositionAndLanguage: .init(disposition: .init(kind: .init(rawValue: $0), parameters: [:]))) }))
    }
    private var html: BodyStructure.Singlepart.Kind { .text(.init(mediaSubtype: .init("html"), lineCount: 1)) }
    private var image: BodyStructure.Singlepart.Kind { .basic(.init(topLevel: .image, sub: .init("png"))) }
    private func section(_ path: [Int]) -> SectionSpecifier { .init(part: .init(path)) }
    private func raw(_ type: String, id: String = "", content: String = "payload") -> Data {
        Data(("Content-Type: \(type)\r\n" + (id.isEmpty ? "" : "Content-ID: <\(id)>\r\n") + "\r\n" + content).utf8)
    }
    @Test func alternativeRelatedScopesSurviveSelectiveReconstruction() throws {
        let tree = BodyStructure.multipart(.init(parts: [
            .multipart(.init(parts: [leaf(html), leaf(image, id: "same@example.test")], mediaSubtype: .init("related"))),
            .multipart(.init(parts: [leaf(html), leaf(image, id: "same@example.test")], mediaSubtype: .init("related")))
        ], mediaSubtype: .alternative))
        let plan = try ReadablePlan(tree)
        #expect(plan.metadataSections.isEmpty)
        let rebuilt = try #require(try plan.assemble([
            section([1,1]): raw("text/html", content: "old"), section([1,2]): raw("image/png", id: "same@example.test", content: "old bytes"),
            section([2,1]): raw("text/html", content: "selected"), section([2,2]): raw("image/png", id: "same@example.test", content: "selected bytes")
        ]))
        #expect(rebuilt.part.contentType.subtype == "alternative")
        let branches = try rebuilt.part.parts
        #expect(branches.map(\.contentType.subtype) == ["related", "related"])
        #expect(try branches[0].parts[1].data == Data("old bytes".utf8))
        #expect(try branches[1].parts[1].data == Data("selected bytes".utf8))
        #expect(try branches[1].parts[1].contentID?.description == "<same@example.test>")
    }
    @Test func explicitMultipartRelatedRootRequestsOnlyRequiredMetadata() throws {
        let tree = BodyStructure.multipart(.init(parts: [leaf(image, id: "image@example.test"),
            .multipart(.init(parts: [leaf(html)], mediaSubtype: .alternative))], mediaSubtype: .init("related"),
            extension: .init(parameters: ["START": "<root@example.test>", "TYPE": "multipart/alternative"], dispositionAndLanguage: nil)))
        let plan = try ReadablePlan(tree), header = SectionSpecifier(part: .init([2]), kind: .MIMEHeader)
        #expect(plan.metadataSections == [header])
        let rebuilt = try #require(try plan.assemble([section([1]): raw("image/png", id: "image@example.test"),
            section([2,1]): raw("text/html", content: "Root")],
            metadata: [header: raw("multipart/alternative; boundary=unused", id: "root@example.test", content: "")]))
        #expect(rebuilt.part.contentTypeParameters["start"] == "<root@example.test>")
        #expect(try rebuilt.part.parts[1].contentID?.description == "<root@example.test>")
        let withoutHeader = try #require(try plan.assemble([section([2,1]): raw("text/html", content: "Root")]))
        #expect(try withoutHeader.part.parts[1].contentID == nil)
    }
    @Test func missingFirstRelatedLeafKeepsAnOmittedSlot() throws {
        let plan = try ReadablePlan(.multipart(.init(parts: [leaf(html, bytes: 4*1024*1024+1), leaf(html)], mediaSubtype: .init("related"))))
        #expect(plan.partial)
        let rebuilt = try #require(try plan.assemble([section([2]): raw("text/html", content: "Auxiliary")]))
        #expect(try rebuilt.part.parts.count == 2)
        #expect(try rebuilt.part.parts[0].contentType == .application("x-dmail-omitted"))
        #expect(try rebuilt.part.parts[1].data == Data("Auxiliary".utf8))
    }
    @Test func referencedGenericImageIsFetchedButOrdinaryBinaryAttachmentIsNot() throws {
        let generic = BodyStructure.Singlepart.Kind.basic(.init(topLevel: .application, sub: .init("octet-stream")))
        let plan = try ReadablePlan(.multipart(.init(parts: [leaf(html), leaf(generic, id: "inline@example.test"), leaf(generic)], mediaSubtype: .init("related"))))
        #expect(plan.parts.map(\.section) == [section([1]), section([2])])
        #expect(plan.attachments.map(\.id) == ["3"])
    }
    @Test func onlyTheRelatedRootMayIgnoreTextAttachmentDisposition() throws {
        let tree = BodyStructure.multipart(.init(parts: [leaf(html, id: "aux@example.test", disposition: "attachment"),
            leaf(html, id: "root@example.test", disposition: "attachment")], mediaSubtype: .init("related"),
            extension: .init(parameters: ["start": "<root@example.test>"], dispositionAndLanguage: nil)))
        let plan = try ReadablePlan(tree)
        #expect(plan.parts.map(\.section) == [section([2])])
        #expect(plan.metadataSections.isEmpty)
    }
    @Test func extendedPDFFilenameIsDecodedWithoutDownloadingItsBody() throws {
        let pdf = BodyStructure.singlepart(.init(kind: .basic(.init(topLevel: .application, sub: .init("pdf"))),
            fields: .init(parameters: [:], id: nil, contentDescription: nil, encoding: .init("base64"), octetCount: 1024),
            extension: .init(digest: nil, dispositionAndLanguage: .init(disposition: .init(kind: .init(rawValue: "attachment"),
                parameters: ["filename*": "utf-8''%E6%8A%A5%E5%91%8A.pdf"])))))
        let plan = try ReadablePlan(pdf)
        #expect(plan.parts.isEmpty)
        #expect(plan.attachments.first?.name == "报告.pdf")
    }
}

// Exercise both actual UID FETCH commands through the original TLS client. A
// server may interleave another message's FLAGS while returning this attachment.
import NIOCore
import NIOPosix
import NIOSSL

private enum AttachmentFetchScenario: Sendable {
    case normal, unrelatedStructureFlags, unrelatedPartFlags, missingStructureTarget, duplicateStructureTarget, missingPartHeader
    case cidOnly, cidOnlyLarge, cidOnlyMixed, emptyTextPDF, emptyTextCID, missingTextPDF
}
private final class AttachmentFetchTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var fetches = 0
    func fetched() { lock.withLock { fetches += 1 } }
    func count() -> Int { lock.withLock { fetches } }
}
private final class AttachmentFetchPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: AttachmentFetchScenario, trace: AttachmentFetchTrace
    var input = ""
    let payload = Data("%PDF-1.4\nSynthetic attachment\n%%EOF".utf8).base64EncodedString()
    let headers = "Content-Type: application/pdf\r\nContent-Disposition: attachment; filename*=utf-8''%E6%8A%A5%E5%91%8A.pdf\r\nContent-Transfer-Encoding: base64\r\n\r\n"
    init(_ scenario: AttachmentFetchScenario, _ trace: AttachmentFetchTrace) { self.scenario = scenario; self.trace = trace }
    func send(_ value: String, _ context: ChannelHandlerContext) { context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil) }
    func literal(_ value: String) -> String { "{\(value.utf8.count)}\r\n\(value)" }
    func channelActive(context: ChannelHandlerContext) { send("* OK Synthetic attachment peer\r\n", context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let end = input.range(of: "\r\n") {
            let line = String(input[..<end.lowerBound]); input.removeSubrange(..<end.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased()
            switch command {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Logged in\r\n", context)
            case "UID":
                trace.fetched()
                if line.contains("BODYSTRUCTURE") {
                    let uid = scenario == .missingStructureTarget ? 8 : 7
                    let pdf = "(\"APPLICATION\" \"PDF\" NIL NIL NIL \"BASE64\" \(payload.utf8.count) NIL (\"ATTACHMENT\" (\"FILENAME\" \"Synthetic.pdf\")) NIL NIL)"
                    let image = "(\"IMAGE\" \"PNG\" NIL \"<picture@example.test>\" NIL \"BASE64\" \(scenario == .cidOnlyLarge ? 8 * 1024 * 1024 : 64) NIL NIL NIL NIL)"
                    let structure: String
                    switch scenario {
                    case .cidOnly, .cidOnlyLarge: structure = image
                    case .cidOnlyMixed: structure = "(\(image) \"MIXED\")"
                    case .emptyTextPDF, .emptyTextCID, .missingTextPDF:
                        structure = "((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" \(scenario == .missingTextPDF ? 40 : 0) 0 NIL NIL NIL NIL)\(scenario == .emptyTextCID ? image : pdf) \"MIXED\")"
                    default: structure = pdf
                    }
                    send("* 1 FETCH (UID \(uid) BODYSTRUCTURE \(structure))\r\n", context)
                    if scenario == .unrelatedStructureFlags { send("* 2 FETCH (UID 8 FLAGS (\\Seen))\r\n* 3 FETCH (FLAGS ())\r\n", context) }
                    if scenario == .duplicateStructureTarget { send("* 2 FETCH (UID 7 FLAGS ())\r\n", context) }
                } else {
                    let section = line.components(separatedBy: "BODY.PEEK[").dropFirst().first?.components(separatedBy: "]").first ?? "1.MIME"
                    if scenario == .emptyTextPDF || scenario == .emptyTextCID || scenario == .missingTextPDF {
                        send("* 1 FETCH (UID 7 BODY[1.MIME] \(literal("Content-Type: text/plain\r\n\r\n")) BODY[1] \(literal("")))\r\n", context)
                    } else if scenario == .missingPartHeader {
                        send("* 1 FETCH (UID 7 BODY[1] \(literal(payload)))\r\n* 2 FETCH (UID 8 BODY[\(section)] \(literal(headers)))\r\n", context)
                    } else {
                        send("* 1 FETCH (UID 7 BODY[\(section)] \(literal(headers)))\r\n* 1 FETCH (UID 7 BODY[1] \(literal(payload)))\r\n", context)
                    }
                    if scenario == .unrelatedPartFlags { send("* 2 FETCH (UID 8 FLAGS (\\Seen))\r\n* 3 FETCH (FLAGS ())\r\n", context) }
                }
                send("\(tag) OK Fetched\r\n", context)
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

struct AttachmentFetchTests {
    @Test func openingAttachmentOnlyMailFinishesWithMetadataAndNoAttachmentDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-attachment-only-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in [AttachmentFetchScenario.normal, .cidOnly, .cidOnlyLarge, .cidOnlyMixed, .emptyTextPDF, .emptyTextCID, .missingTextPDF] {
                let trace = AttachmentFetchTrace()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), AttachmentFetchPeer(scenario, trace)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 2)
                do {
                    try await client.connect(); try await client.login()
                    let readable = try #require(try await client.fetchReadable(uid: 7))
                    #expect(readable.hasAttachments)
                    #expect(readable.partial == (scenario == .missingTextPDF))
                    #expect(readable.attachments.count == 1)
                    let emptyText = scenario == .emptyTextPDF || scenario == .emptyTextCID || scenario == .missingTextPDF
                    #expect(readable.attachments[0].id == (emptyText ? "2" : "1"))
                    if emptyText {
                        #expect(try readable.body?.part.parts[0].data.isEmpty == true)
                        #expect(try readable.body?.part.parts[0].contentType.subtype == (scenario == .missingTextPDF ? "x-dmail-omitted" : "plain"))
                        #expect(trace.count() == 2)
                    } else {
                        #expect(readable.body == nil)
                        #expect(trace.count() == 1)
                    }
                    try await client.shutdown(); #expect(!client.isConnected)
                } catch { try? await client.shutdown(); try? await server.close().get(); throw error }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    @Test func selectedAttachmentSurvivesUnrelatedFlagsInEitherFetch() async throws {
        try await run([.normal, .unrelatedStructureFlags, .unrelatedPartFlags], success: true)
    }
    @Test func wrongDuplicateAndIncompleteTargetsNeverBorrowAnotherMessagesAttachment() async throws {
        try await run([.missingStructureTarget, .duplicateStructureTarget, .missingPartHeader], success: false)
    }
    private func run(_ scenarios: [AttachmentFetchScenario], success: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-attachment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in scenarios {
                let trace = AttachmentFetchTrace()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), AttachmentFetchPeer(scenario, trace)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 2)
                do {
                    try await client.connect(); try await client.login()
                    do {
                        let part = try await client.fetchAttachment(uid: 7, id: "1")
                        #expect(success)
                        #expect(part.contentDisposition?.file?.filename == "报告.pdf")
                        #expect(Data(base64Encoded: part.data) == Data("%PDF-1.4\nSynthetic attachment\n%%EOF".utf8))
                    } catch { #expect(!success, "\(scenario): \(error)") }
                    #expect(trace.count() == (scenario == .missingStructureTarget || scenario == .duplicateStructureTarget ? 1 : 2))
                    try await client.shutdown(); #expect(!client.isConnected)
                } catch { try? await client.shutdown(); try? await server.close().get(); throw error }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}

struct ReadableFetchBatchPlanTests {
    private func batches(_ sizes: [Int]) -> [Range<Int>] {
        readableFetchBatches(sizes.enumerated().map { ReadablePart(section: .init(part: .init([$0.offset + 1])), octets: $0.element) })
    }
    @Test func pairsKeepOrderAndRespectHeaderAndContentBudget() {
        #expect(batches([]).isEmpty)
        #expect(batches([1]) == [0..<1])
        #expect(batches([1, 2, 3, 4, 5]) == [0..<2, 2..<4, 4..<5])
        #expect(batches([0, 384 * 1024]) == [0..<2])
        #expect(batches([1, 384 * 1024]) == [0..<1, 1..<2])
        #expect(batches([4 * 1024 * 1024, 1, 2]) == [0..<1, 1..<3])
        #expect(batches([Int.max, Int.max, -1, 0]) == [0..<1, 1..<2, 2..<3, 3..<4])
    }
}

private enum BatchedBodyScenario: Sendable {
    case combined, splitReversed, missingHeader, missingContent, malformedHeader, oversizedHeader
    case foreignHeader, wrongUID, duplicateUID, conflictingUID, rejected
}
private final class BatchedBodyPeer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    let scenario: BatchedBodyScenario, trace: AttachmentFetchTrace
    var input = ""
    init(_ scenario: BatchedBodyScenario, _ trace: AttachmentFetchTrace) { self.scenario = scenario; self.trace = trace }
    func send(_ value: String, _ context: ChannelHandlerContext) { context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: value)), promise: nil) }
    func literal(_ value: String) -> String { "{\(value.utf8.count)}\r\n\(value)" }
    func channelActive(context: ChannelHandlerContext) { send("* OK Synthetic MIME batch peer\r\n", context) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        input += String(buffer: unwrapInboundIn(data))
        while let end = input.range(of: "\r\n") {
            let line = String(input[..<end.lowerBound]); input.removeSubrange(..<end.upperBound)
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2 else { context.close(promise: nil); return }
            let tag = String(fields[0]), command = String(fields[1]).uppercased()
            switch command {
            case "CAPABILITY": send("* CAPABILITY IMAP4rev1\r\n\(tag) OK Capabilities\r\n", context)
            case "LOGIN": send("\(tag) OK Logged in\r\n", context)
            case "UID":
                trace.fetched()
                if line.contains("BODYSTRUCTURE") {
                    send("* 1 FETCH (UID 7 BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" NIL NIL NIL \"7BIT\" 5 1)(\"TEXT\" \"HTML\" NIL NIL NIL \"7BIT\" 12 1) \"ALTERNATIVE\"))\r\n", context)
                } else {
                    // A single part at a time is deliberately refused: this
                    // fixture verifies the actual request, not just the planner.
                    guard ["BODY.PEEK[1.MIME]", "BODY.PEEK[1]", "BODY.PEEK[2.MIME]", "BODY.PEEK[2]"].allSatisfy(line.contains) else {
                        send("\(tag) BAD Expected paired PEEK\r\n", context); continue
                    }
                    if scenario == .rejected { send("\(tag) NO Synthetic refusal\r\n", context); continue }
                    let plainHeader = "Content-Type: text/plain; charset=utf-8\r\n\r\n"
                    var htmlHeader = "Content-Type: text/html; charset=utf-8\r\n\r\n"
                    if scenario == .malformedHeader { htmlHeader = "Content-Type: impossible\r\n\r\n" }
                    if scenario == .oversizedHeader { htmlHeader += String(repeating: "x", count: 65537) }
                    let plain = "BODY[1.MIME] \(literal(plainHeader)) BODY[1] \(literal("hello"))"
                    var html = ""
                    if scenario != .missingHeader && scenario != .foreignHeader { html += "BODY[2.MIME] \(literal(htmlHeader)) " }
                    if scenario != .missingContent { html += "BODY[2] \(literal("<p>hello</p>"))" }
                    let uid = scenario == .wrongUID ? 8 : 7
                    if scenario == .splitReversed {
                        send("* 1 FETCH (UID 7 \(html))\r\n* 2 FETCH (UID 8 FLAGS (\\Seen))\r\n* 1 FETCH (FLAGS ())\r\n* 1 FETCH (UID 7 \(plain))\r\n", context)
                    } else {
                        send("* 1 FETCH (UID \(uid) \(plain) \(html))\r\n", context)
                    }
                    if scenario == .foreignHeader { send("* 2 FETCH (UID 8 BODY[2.MIME] \(literal(htmlHeader)))\r\n", context) }
                    if scenario == .duplicateUID { send("* 2 FETCH (UID 7 FLAGS ())\r\n", context) }
                    if scenario == .conflictingUID { send("* 1 FETCH (UID 8 FLAGS ())\r\n", context) }
                }
                send("\(tag) OK Fetched\r\n", context)
            default: send("\(tag) BAD Unexpected command\r\n", context)
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

struct BatchedReadableFetchTests {
    @Test func combinedAndSplitReversedResponsesPreserveBothAlternatives() async throws {
        try await run([.combined, .splitReversed], partial: false, fails: false)
    }
    @Test func missingOrInvalidSiblingPreservesUsablePlainText() async throws {
        try await run([.missingHeader, .missingContent, .malformedHeader, .oversizedHeader, .foreignHeader], partial: true, fails: false)
    }
    @Test func ambiguousTargetsAndRejectedBatchFailWithoutReplay() async throws {
        try await run([.wrongUID, .duplicateUID, .conflictingUID, .rejected], partial: false, fails: true)
    }
    private func run(_ scenarios: [BatchedBodyScenario], partial: Bool, fails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dmail-mime-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try NIOSSLContext(configuration: fixtureTLSConfiguration(in: directory))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            for scenario in scenarios {
                let trace = AttachmentFetchTrace()
                let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
                    channel.pipeline.addHandlers([NIOSSLServerHandler(context: context), BatchedBodyPeer(scenario, trace)])
                }.bind(host: "127.0.0.1", port: 0).get()
                guard let port = server.localAddress?.port else { throw IMAPError.notConnected }
                var tls = TLSConfiguration.makeClientConfiguration(); tls.certificateVerification = .none
                let client = IMAPClient(Server(hostname: "127.0.0.1", username: "synthetic", password: "synthetic", port: port),
                    logger: nil, tlsConfiguration: tls, connectionTimeout: .seconds(2), commandTimeout: 2)
                do {
                    try await client.connect(); try await client.login()
                    do {
                        let readable = try #require(try await client.fetchReadable(uid: 7))
                        #expect(!fails, "\(scenario)")
                        #expect(readable.partial == partial, "\(scenario)")
                        let body = try #require(readable.body)
                        let children = try body.part.parts
                        #expect(children.count == 2)
                        #expect(String(decoding: children[0].data, as: UTF8.self).hasPrefix("hello"))
                        if partial { #expect(children[1].contentType.subtype == "x-dmail-omitted") }
                        else { #expect(String(decoding: children[1].data, as: UTF8.self).hasPrefix("<p>hello</p>")) }
                    } catch { #expect(fails, "\(scenario): \(error)") }
                    #expect(trace.count() == 2, "\(scenario): no individual retry")
                    try await client.shutdown(); #expect(!client.isConnected)
                } catch { try? await client.shutdown(); try? await server.close().get(); throw error }
                try await server.close().get()
            }
            try await group.shutdownGracefully()
        } catch { try? await group.shutdownGracefully(); throw error }
    }
}
