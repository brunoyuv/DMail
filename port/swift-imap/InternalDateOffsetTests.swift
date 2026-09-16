// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import Testing
@testable import IMAP
import NIOIMAPCore

struct InternalDateOffsetTests {
    @Test func localClockFieldsRespectPositiveNegativeAndFractionalOffsets() throws {
        // All of these represent 2026-09-15 23:00 UTC = Sep 16, 08:00 in Tokyo.
        let expected = Date(timeIntervalSince1970: 1789513200)
        for source in ["16-Sep-2026 08:00:00 +0900", "15-Sep-2026 23:00:00 +0000",
                       "15-Sep-2026 16:00:00 -0700", "16-Sep-2026 04:30:00 +0530",
                       "16-Sep-2026 04:45:00 +0545", "15-Sep-2026 19:30:00 -0330"] {
            #expect(try Date(serverMessageDate: source) == expected)
            #expect(try Date(serverMessageDate: "\"\(source)\"") == expected)
        }
        let components = ServerMessageDate.Components(year: 2026, month: 9, day: 16, hour: 8, minute: 0, second: 0, timeZoneMinutes: 540)!
        #expect(try Date(serverMessageDate: ServerMessageDate(components)) == expected)
    }
    @Test func offsetParsingRejectsMalformedOffsetsAndPreservesLegacyUtcFormatting() throws {
        for source in ["16-Sep-2026 08:00:00 +0960", "16-Sep-2026 08:00:00 +2400", "16-Sep-2026 08:00:00 +09xx"] {
            #expect(throws: (any Error).self) { try Date(serverMessageDate: source) }
        }
        let utc = try Date(serverMessageDate: "16-Sep-2026 08:00:00")
        #expect(utc.serverMessageDateFormat() == "16-Sep-2026 08:00:00 +0000")
    }
}
