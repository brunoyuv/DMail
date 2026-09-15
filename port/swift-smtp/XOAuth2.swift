// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

func xoauth2Payload(username: String, accessToken: String) throws -> String {
    guard !username.isEmpty, username.utf8.count <= 512,
          !username.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
          !accessToken.isEmpty, accessToken.utf8.count <= 32768,
          accessToken.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw SMTPError.authenticationRequired }
    return Data("user=\(username)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}".utf8).base64EncodedString()
}
