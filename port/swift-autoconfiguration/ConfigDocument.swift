// Parse provider/Thunderbird ISPDB data using the upstream XML parser and models.
import Foundation

extension ClientConfig {
    public static func parse(_ data: Data, emailAddress: String) throws -> ClientConfig {
        guard !emailAddress.isEmpty, emailAddress.utf8.count <= 320,
              !emailAddress.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw URLError(.badURL)
        }
        let json = try XMLToJSONParser(emailAddress, data: data).data
        let config = try JSONDecoder().decode(ConfigContainer.self, from: json).clientConfig
        guard config.emailProvider != nil || config.webMail != nil else { throw URLError(.cannotParseResponse) }
        return config
    }
}

private struct ConfigContainer: Decodable { let clientConfig: ClientConfig }
