// MPL-2.0: https://mozilla.org/MPL/2.0/
import Foundation

public enum MailOAuthProvider: String, Codable, Sendable {
    case google, microsoft

    public func registration(clientID: String, redirectURI: String, microsoftPersonalOnly: Bool = false) throws -> OAuth2.Request {
        let request: OAuth2.Request
        switch self {
        case .google:
            request = try OAuth2.Request(authURI: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenURI: "https://oauth2.googleapis.com/token", redirectURI: redirectURI,
                responseType: "code", scope: ["https://mail.google.com/"], clientID: clientID,
                hosts: ["imap.gmail.com", "smtp.gmail.com"])
        case .microsoft:
            let audience = microsoftPersonalOnly ? "consumers" : "common"
            request = try OAuth2.Request(authURI: "https://login.microsoftonline.com/\(audience)/oauth2/v2.0/authorize",
                tokenURI: "https://login.microsoftonline.com/\(audience)/oauth2/v2.0/token", redirectURI: redirectURI,
                responseType: "code", scope: ["https://outlook.office.com/IMAP.AccessAsUser.All",
                    "https://outlook.office.com/SMTP.Send", "offline_access"], clientID: clientID,
                hosts: ["outlook.office365.com", "smtp.office365.com"])
        }
        try BrowserOAuthSessions.validate(request)
        return request
    }

    public var authorizationParameters: [String: String] {
        switch self {
        case .google: ["access_type": "offline", "prompt": "consent"]
        case .microsoft: ["prompt": "select_account"]
        }
    }
}
