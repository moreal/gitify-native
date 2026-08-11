import Foundation

/// Per-class error pane content (gitify/src/renderer/utils/core/errors.ts),
/// shared by the full-pane error state and per-account inline error blocks.
extension APIErrorKind {
    var icon: String {
        switch self {
        case .badCredentials: "person.crop.circle.badge.xmark"
        case .missingScopes: "key.slash"
        case .rateLimited: "hourglass"
        case .network: "wifi.exclamationmark"
        case .unknown: "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .badCredentials: "Bad credentials"
        case .missingScopes: "Missing scopes"
        case .rateLimited: "Rate limited"
        case .network: "Network error"
        case .unknown: "Oops! Something went wrong"
        }
    }

    var guidance: String {
        switch self {
        case .badCredentials:
            "Your credentials are either invalid or expired. Sign out and sign in again."
        case .missingScopes:
            "Your credentials are missing a required API scope. Re-authorize with the notifications scope."
        case .rateLimited:
            "Please wait a while before trying again."
        case .network:
            "Unable to connect to GitHub. Please check your network connection, including whether you require a VPN, and try again."
        case .unknown:
            "Please try again later."
        }
    }

    /// Credential-class failures are fixed in account management (sign out / re-auth).
    var needsAccountAction: Bool {
        self == .badCredentials || self == .missingScopes
    }
}
