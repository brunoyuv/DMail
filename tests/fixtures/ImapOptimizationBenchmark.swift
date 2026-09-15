// Synthetic IMAP sync workload. No sockets, accounts or external message data.
import Foundation
import NIO
import NIOIMAP

let messageCount = 120
let iterations = Int(CommandLine.arguments.dropFirst().first ?? "12")!
precondition((1...200).contains(iterations))
let html = "<html><body>" + String(repeating: "<p>Fixture newsletter: physics, UTF-8 日本語, and a saved picture.</p>", count: 120) + "</body></html>"
let htmlBytes = html.utf8.count
let plain = "Synthetic message text. No real mail.\r\n"
var wire = "* 120 EXISTS\r\n* OK [UIDVALIDITY 73] Fixture\r\n"
for index in 1...messageCount {
    wire += "* \(index) FETCH (UID \(index + 1000) FLAGS (\\Seen) ENVELOPE (\"Tue, 15 Sep 2026 10:00:00 +0000\" \"=?UTF-8?B?U3ludGhldGljIG5ld3NsZXR0ZXI=?=\" ((\"Fixture Sender\" NIL \"sender\" \"example.invalid\")) NIL NIL ((NIL NIL \"reader\" \"example.invalid\")) NIL NIL NIL \"<fixture-\(index)@example.invalid>\") BODYSTRUCTURE ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" \(plain.utf8.count) 1 NIL NIL NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"8BIT\" \(htmlBytes) 120 NIL NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"fixture\") NIL NIL NIL))\r\n"
    wire += "* \(index) FETCH (UID \(index + 1000) BODY[2] {\(htmlBytes)}\r\n\(html))\r\n"
}
wire += "A9 OK FETCH completed\r\n"
let input = ByteBuffer(string: wire)
var responseCount = 0
var starts = 0
var finishes = 0
var bodyBytes = 0
var bodyChunks = 0
let start = DispatchTime.now().uptimeNanoseconds
for _ in 0..<iterations {
    var parser = ResponseParser()
    var source = input
    var pending = ByteBufferAllocator().buffer(capacity: 8192)
    while var fragment = source.readSlice(length: min(4096, source.readableBytes)), fragment.readableBytes > 0 {
        pending.writeBuffer(&fragment)
        while let response = try parser.parseResponseStream(buffer: &pending) {
            responseCount += 1
            if case .response(.fetch(let fetch)) = response {
                switch fetch {
                case .start, .startUID: starts += 1
                case .finish: finishes += 1
                case .streamingBytes(let bytes):
                    bodyBytes += bytes.readableBytes
                    bodyChunks += 1
                default: break
                }
            }
        }
        pending.discardReadBytes()
    }
    precondition(source.readableBytes == 0 && pending.readableBytes == 0)
}
let elapsed = DispatchTime.now().uptimeNanoseconds - start
precondition(starts == messageCount * 2 * iterations)
precondition(finishes == starts)
precondition(bodyBytes == htmlBytes * messageCount * iterations)
let result: [String: Any] = [
    "messagesPerIteration": messageCount, "iterations": iterations,
    "inputBytes": input.readableBytes, "responses": responseCount,
    "fetchStarts": starts, "fetchFinishes": finishes,
    "bodyBytes": bodyBytes, "bodyChunks": bodyChunks,
    "elapsedNanoseconds": elapsed
]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
