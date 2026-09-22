import Foundation

/// Test-only GitHub backend, active when the app is launched with
/// `--uitest-mock-github` (see GitifyUITests). Keeps UI tests hermetic:
/// canned notifications are served through a URLProtocol registered on the
/// GitHubClient session, and stores read from an isolated defaults suite so
/// the developer's real accounts, Keychain entries and settings are untouched.
enum UITestMock {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--uitest-mock-github")
    static func shouldStartUpdater(isUITestActive: Bool = isActive) -> Bool {
        !isUITestActive
    }

    static let isLandingScreenshot = ProcessInfo.processInfo.arguments.contains("--uitest-landing-screenshot")
    static var landingScreenshotOutputURL: URL? {
        guard isLandingScreenshot,
              let path = ProcessInfo.processInfo.environment["GITIFY_LANDING_SCREENSHOT_PATH"],
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Opens the popover shortly after launch. Synthesized menu bar clicks are
    /// unreliable (fullscreen spaces, crowded menu bars, the notch), so UI
    /// tests use this instead of clicking the status item; togglePopover() is
    /// the same code path the click handler runs.
    static let shouldAutoOpenPopover = ProcessInfo.processInfo.arguments.contains("--uitest-open-popover")

    /// Number of unread notifications initially served by the mock. Two digits,
    /// so marking one as done changes the tray count's rendered width (10 → 9).
    static var notificationCount: Int { isLandingScreenshot ? landingNotifications.count : 10 }

    struct LandingNotification {
        let title: String
        let reason: String
        let type: String
        let repositoryID: Int
        let repository: String
        let owner: String
    }

    /// Fictional but product-realistic content reserved for the public landing
    /// screenshot. It never reaches normal UI regression tests or real accounts.
    static let landingNotifications: [Int: LandingNotification] = [
        1: LandingNotification(
            title: "Northstar v2.4.0 is ready",
            reason: "subscribed",
            type: "Release",
            repositoryID: 2,
            repository: "sample-cloud/northstar-desktop",
            owner: "sample-cloud"
        ),
        2: LandingNotification(
            title: "Ideas for the next notification filters",
            reason: "comment",
            type: "Discussion",
            repositoryID: 2,
            repository: "sample-cloud/northstar-desktop",
            owner: "sample-cloud"
        ),
        3: LandingNotification(
            title: "Menu bar count shifts after refresh",
            reason: "mention",
            type: "Issue",
            repositoryID: 1,
            repository: "example-studio/orbit-macos",
            owner: "example-studio"
        ),
        4: LandingNotification(
            title: "Polish the macOS onboarding flow",
            reason: "review_requested",
            type: "PullRequest",
            repositoryID: 1,
            repository: "example-studio/orbit-macos",
            owner: "example-studio"
        ),
        5: LandingNotification(
            title: "Reduce idle CPU usage while polling",
            reason: "assign",
            type: "PullRequest",
            repositoryID: 1,
            repository: "example-studio/orbit-macos",
            owner: "example-studio"
        ),
        6: LandingNotification(
            title: "macOS release build completed",
            reason: "ci_activity",
            type: "WorkflowRun",
            repositoryID: 3,
            repository: "pixel-forge/canvas-kit",
            owner: "pixel-forge"
        ),
        7: LandingNotification(
            title: "Update keyboard navigation in filters",
            reason: "team_mention",
            type: "PullRequest",
            repositoryID: 3,
            repository: "pixel-forge/canvas-kit",
            owner: "pixel-forge"
        ),
        8: LandingNotification(
            title: "Security update available for parser",
            reason: "security_alert",
            type: "RepositoryVulnerabilityAlert",
            repositoryID: 3,
            repository: "pixel-forge/canvas-kit",
            owner: "pixel-forge"
        ),
    ]

    static let account = Account(
        user: GHUser(
            id: 1,
            login: "octocat",
            name: "Mock Octocat",
            avatarUrl: "https://example.invalid/avatar.png",
            htmlUrl: "https://github.com/octocat"
        ),
        hostname: "github.com",
        authMethod: .personalAccessToken,
        scopes: ["notifications"]
    )

    /// Fresh defaults suite pinned to the values the UI tests rely on.
    static func makeDefaults() -> UserDefaults {
        let suiteName = "dev.moreal.gitify.uitests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "showCountInTray")
        defaults.set(false, forKey: "detailedNotifications")
        defaults.set(false, forKey: "showNotificationBanners")
        defaults.set(false, forKey: "playSound")
        defaults.set(false, forKey: "openAtStartup")
        defaults.set(false, forKey: "showAccountHeader")
        defaults.set(3600.0, forKey: "fetchInterval")
        if isLandingScreenshot {
            // Keep CI and local captures visually identical regardless of the
            // runner's appearance setting.
            defaults.set("light", forKey: "theme")
        }
        return defaults
    }
}

/// Serves the GitHub REST endpoints the app consumes from an in-memory unread
/// set, so mark-as-done/read behave like the real API: the thread disappears
/// from subsequent /notifications responses instead of reappearing on refetch.
final class UITestMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var unreadIDs: Set<Int>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.respond(to: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock()
        defer { lock.unlock() }
        var ids = unreadIDs ?? Set(1...UITestMock.notificationCount)
        defer { unreadIDs = ids }

        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        if method == "GET", path == "/notifications" {
            // Honor pagination so the client's fetch-all loop terminates even
            // if the mock ever serves more than one page's worth of items.
            let query = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            } ?? []
            let page = query.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
            let perPage = query.first { $0.name == "per_page" }?.value.flatMap(Int.init) ?? 50
            let sorted = ids.sorted()
            let start = (page - 1) * perPage
            let slice = start < sorted.count
                ? Array(sorted[start..<min(start + perPage, sorted.count)])
                : []
            return (200, notificationsJSON(slice))
        }
        if path.hasPrefix("/notifications/threads/") {
            let last = path.split(separator: "/").last.map(String.init) ?? ""
            if last == "subscription" {
                return (200, Data(#"{"ignored":true}"#.utf8))
            }
            if let threadID = Int(last), method == "PATCH" || method == "DELETE" {
                ids.remove(threadID - 1000)
                return (method == "DELETE" ? 204 : 205, Data())
            }
        }
        return (200, Data("{}".utf8))
    }

    private static func notificationsJSON(_ ids: [Int]) -> Data {
        let items = ids.map { id -> [String: Any] in
            let landing = UITestMock.isLandingScreenshot
                ? UITestMock.landingNotifications[id]
                : nil
            return [
                "id": String(1000 + id),
                "unread": true,
                "reason": landing?.reason ?? "subscribed",
                "updated_at": landingTimestamp(id: id),
                "last_read_at": NSNull(),
                "subject": [
                    // A nil subject URL keeps enrichment and web-open resolution inert.
                    "title": landing?.title ?? "Mock notification #\(id)",
                    "url": NSNull(),
                    "latest_comment_url": NSNull(),
                    "type": landing?.type ?? "Issue",
                ],
                "repository": [
                    "id": landing?.repositoryID ?? 1,
                    "full_name": landing?.repository ?? "gitify/mock-repo",
                    "html_url": "https://github.com/\(landing?.repository ?? "gitify/mock-repo")",
                    "owner": [
                        "login": landing?.owner ?? "gitify",
                        "avatar_url": "https://example.invalid/avatar.png",
                    ],
                ],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: items)
    }

    private static func landingTimestamp(id: Int) -> String {
        guard UITestMock.isLandingScreenshot else {
            // Fixed timestamps keep normal regression-test ordering stable.
            return String(format: "2026-08-01T00:00:%02dZ", id)
        }
        let minutesAgo = UITestMock.notificationCount - id + 1
        return ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60))
        )
    }
}
