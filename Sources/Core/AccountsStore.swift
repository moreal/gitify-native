import Foundation
import Combine

/// Persists accounts (metadata in UserDefaults, tokens in Keychain) and handles login/logout.
@MainActor
final class AccountsStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []

    private let defaults: UserDefaults
    private static let storageKey = "accounts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = stored
        }
    }

    var isAuthenticated: Bool { !accounts.isEmpty }

    func client(for account: Account) -> GitHubClient? {
        guard let token = Keychain.token(for: account.id) else { return nil }
        return GitHubClient(baseURL: account.apiBaseURL, token: token)
    }

    /// Validates the token against /user, then persists the account.
    @discardableResult
    func addAccount(token: String, hostname: String, method: Account.AuthMethod) async throws -> Account {
        let baseURL = hostname == "github.com"
            ? URL(string: "https://api.github.com")!
            : URL(string: "https://\(hostname)/api/v3")!
        let client = GitHubClient(baseURL: baseURL, token: token)
        let (user, scopes) = try await client.authenticatedUser()
        let account = Account(user: user, hostname: hostname, authMethod: method, scopes: scopes)
        try Keychain.setToken(token, for: account.id)
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        persist()
        return account
    }

    func removeAccount(_ account: Account) {
        Keychain.deleteToken(for: account.id)
        accounts.removeAll { $0.id == account.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(accounts), forKey: Self.storageKey)
    }
}
