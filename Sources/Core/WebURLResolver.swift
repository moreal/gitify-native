import Foundation

/// Resolves the browser URL for a notification, mirroring Gitify
/// (gitify/src/renderer/utils/notifications/url.ts): prefer the latest
/// comment's html_url, then the subject's, then a per-type repo fallback,
/// always tagged with notification_referrer_id.
enum WebURLResolver {
    static func url(
        for notification: GHNotification,
        detail: SubjectDetail?,
        account: Account,
        client: GitHubClient?
    ) async -> URL {
        var resolved = defaultURL(for: notification)

        if let latest = notification.subject.latestCommentUrl,
           let html = await htmlURL(following: latest, client: client) {
            resolved = html
        } else if let html = detail?.htmlUrl.flatMap(URL.init(string:)) {
            resolved = html
        } else if let subjectURL = notification.subject.url,
                  let html = await htmlURL(following: subjectURL, client: client) {
            resolved = html
        }

        return addingReferrer(to: resolved, notification: notification, account: account)
    }

    private static func htmlURL(following apiURLString: String, client: GitHubClient?) async -> URL? {
        guard let client, let apiURL = URL(string: apiURLString),
              let json = try? await client.subjectDetail(apiURL: apiURL),
              let html = json["html_url"] as? String
        else { return nil }
        return URL(string: html)
    }

    /// Per-type fallback under the repository page
    /// (gitify/src/renderer/utils/forges/github/handlers/*.ts getDisplayHelpers).
    static func defaultURL(for notification: GHNotification) -> URL {
        let base = notification.repository.htmlUrl
        let suffix: String
        switch notification.subject.type {
        case .issue: suffix = "/issues"
        case .pullRequest: suffix = "/pulls"
        case .discussion: suffix = "/discussions"
        case .release: suffix = "/releases"
        case .checkSuite, .workflowRun: suffix = "/actions"
        case .repositoryAdvisory: suffix = "/security/advisories"
        case .repositoryDependabotAlertsThread: suffix = "/security/dependabot"
        case .repositoryInvitation: suffix = "/invitations"
        default: suffix = ""
        }
        return URL(string: base + suffix) ?? URL(string: base)!
    }

    private static func addingReferrer(
        to url: URL,
        notification: GHNotification,
        account: Account
    ) -> URL {
        let raw = "018:NotificationThread\(notification.id):\(account.user.id)"
        let referrer = Data(raw.utf8).base64EncodedString()
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "notification_referrer_id", value: referrer))
        components.queryItems = query
        return components.url ?? url
    }
}
