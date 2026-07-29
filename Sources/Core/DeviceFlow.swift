import Foundation

/// GitHub OAuth Device Flow (https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow)
enum DeviceFlow {
    struct CodeResponse: Codable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    struct FlowError: LocalizedError {
        let code: String
        var errorDescription: String? {
            switch code {
            case "expired_token": return "The device code expired. Please try again."
            case "access_denied": return "Authorization was denied on GitHub."
            default: return "Device flow failed: \(code)"
            }
        }
    }

    private static func post(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Gitify's scope tiers (constants.ts): RECOMMENDED grants private-repo detail,
    /// ALTERNATE only public-repo detail.
    static let recommendedScopes = "notifications read:user repo"
    static let alternateScopes = "notifications read:user public_repo"

    /// Step 1: request a device + user code pair.
    static func requestCode(
        clientID: String,
        scopes: String = recommendedScopes,
        hostname: String = "github.com"
    ) async throws -> CodeResponse {
        let url = URL(string: "https://\(hostname)/login/device/code")!
        let json = try await post(url, form: ["client_id": clientID, "scope": scopes])
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(CodeResponse.self, from: data)
    }

    /// Step 2: poll until the user authorizes (or the code expires). Returns the access token.
    static func pollForToken(clientID: String, code: CodeResponse, hostname: String = "github.com") async throws -> String {
        let url = URL(string: "https://\(hostname)/login/oauth/access_token")!
        var interval = TimeInterval(code.interval)
        let deadline = Date(timeIntervalSinceNow: TimeInterval(code.expiresIn))

        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            let json = try await post(url, form: [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down":
                interval = TimeInterval(json["interval"] as? Int ?? Int(interval) + 5)
            case let .some(error): throw FlowError(code: error)
            case nil: throw FlowError(code: "unexpected response")
            }
        }
        throw FlowError(code: "expired_token")
    }
}
