// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation
import FoundationNetworking

struct GoogleDesktopRegistration: Sendable {
    let clientID: String
    let clientSecret: String
}

enum GoogleDesktopAuthentication {
    // Google's Desktop registration requires its issued client_secret even with
    // PKCE. Attach it only to the registered client's Google token POST, never
    // an authorization URL, unrelated client, or Microsoft request.
    static func apply(_ input: URLRequest,
                      registration: GoogleDesktopRegistration? = LocalGoogleOAuth.registration) throws -> URLRequest {
        guard let registration,
              input.url?.absoluteString == "https://oauth2.googleapis.com/token",
              input.httpMethod == "POST",
              input.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
              let body = input.httpBody, body.count <= 128 * 1024,
              let text = String(data: body, encoding: .utf8),
              let fields = URLComponents(string: "https://local.invalid/?" + text)?.queryItems
        else { return input }
        guard fields.filter({ $0.name == "client_id" }).count == 1,
              fields.first(where: { $0.name == "client_id" })?.value == registration.clientID
        else { return input }
        guard !registration.clientSecret.isEmpty, registration.clientSecret.utf8.count <= 512,
              registration.clientSecret.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              !fields.contains(where: { $0.name == "client_secret" }),
              fields.filter({ $0.name == "grant_type" }).count == 1,
              ["authorization_code", "refresh_token"].contains(fields.first(where: { $0.name == "grant_type" })?.value ?? "")
        else { throw BrowserOAuthError.invalidConfiguration }
        var encoded = URLComponents()
        encoded.queryItems = [URLQueryItem(name: "client_secret", value: registration.clientSecret)]
        let parameter = encoded.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
        var output = input
        output.httpBody = Data((text + "&" + parameter).utf8)
        return output
    }
}
