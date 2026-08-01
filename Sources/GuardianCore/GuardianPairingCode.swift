import Foundation

public enum GuardianPairingCodeError: Error, Equatable, Sendable {
    case invalidPayload
}

public enum GuardianPairingCode {
    public static let maximumPayloadBytes = 64 * 1_024

    public static func encode(_ invitation: GuardianSignedPairingPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(invitation)
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else {
            throw GuardianPairingCodeError.invalidPayload
        }
        let value = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "codexguardian"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "payload", value: value)]
        guard let code = components.string else {
            throw GuardianPairingCodeError.invalidPayload
        }
        return code
    }
}
