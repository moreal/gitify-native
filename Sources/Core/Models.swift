import Foundation

// MARK: - GitHub REST models (only fields the app consumes)

struct GHNotification: Codable, Identifiable, Equatable {
    let id: String
    var unread: Bool
    let reason: String
    let updatedAt: Date
    let lastReadAt: Date?
    let subject: Subject
    let repository: Repository

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, subject, repository
        case updatedAt = "updated_at"
        case lastReadAt = "last_read_at"
    }

    struct Subject: Codable, Equatable {
        let title: String
        let url: String?
        let latestCommentUrl: String?
        let type: SubjectType

        enum CodingKeys: String, CodingKey {
            case title, url, type
            case latestCommentUrl = "latest_comment_url"
        }
    }

    struct Repository: Codable, Equatable {
        let id: Int
        let fullName: String
        let htmlUrl: String
        let owner: Owner

        enum CodingKeys: String, CodingKey {
            case id, owner
            case fullName = "full_name"
            case htmlUrl = "html_url"
        }

        struct Owner: Codable, Equatable {
            let login: String
            let avatarUrl: String

            enum CodingKeys: String, CodingKey {
                case login
                case avatarUrl = "avatar_url"
            }
        }
    }
}

enum SubjectType: String, Codable, CaseIterable {
    case issue = "Issue"
    case pullRequest = "PullRequest"
    case commit = "Commit"
    case release = "Release"
    case discussion = "Discussion"
    case checkSuite = "CheckSuite"
    case workflowRun = "WorkflowRun"
    case repositoryAdvisory = "RepositoryAdvisory"
    case repositoryVulnerabilityAlert = "RepositoryVulnerabilityAlert"
    case repositoryInvitation = "RepositoryInvitation"
    case repositoryDependabotAlertsThread = "RepositoryDependabotAlertsThread"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SubjectType(rawValue: raw) ?? .unknown
    }
}

struct GHUser: Codable, Equatable {
    let id: Int
    let login: String
    let name: String?
    let avatarUrl: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarUrl = "avatar_url"
        case htmlUrl = "html_url"
    }
}

// MARK: - Account

struct Account: Codable, Identifiable, Equatable {
    /// Keychain lookup key and stable identity: "login@hostname"
    var id: String { "\(user.login)@\(hostname)" }
    let user: GHUser
    /// e.g. "github.com" or a GitHub Enterprise Server host
    let hostname: String
    let authMethod: AuthMethod
    /// OAuth scopes granted to the token (x-oauth-scopes header at login).
    var scopes: [String]?

    enum AuthMethod: String, Codable {
        case personalAccessToken = "Personal Access Token"
        case oauthDeviceFlow = "GitHub App"
    }

    var apiBaseURL: URL {
        Self.apiBaseURL(for: hostname)
    }

    /// github.com → api.github.com; GitHub Enterprise Cloud with data
    /// residency (*.ghe.com) → api.<hostname>; GHES → <hostname>/api/v3
    /// (upstream getGitHubAPIBaseUrl). Device flow endpoints always live on
    /// the hostname itself.
    static func apiBaseURL(for hostname: String) -> URL {
        if hostname == "github.com" {
            return URL(string: "https://api.github.com")!
        }
        if hostname.hasSuffix(".ghe.com") {
            return URL(string: "https://api.\(hostname)")!
        }
        return URL(string: "https://\(hostname)/api/v3")!
    }

    var webBaseURL: URL {
        URL(string: "https://\(hostname)")!
    }

    /// The signed-in user's profile page.
    var profileURL: URL {
        URL(string: user.htmlUrl) ?? webBaseURL.appending(path: user.login)
    }
}
