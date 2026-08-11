import Foundation

/// Test-only GitHub backend, active when the app is launched with
/// `--uitest-mock-github` (see GitifyUITests). Keeps UI tests hermetic:
/// canned notifications are served through a URLProtocol registered on the
/// GitHubClient session, and stores read from an isolated defaults suite so
/// the developer's real accounts, Keychain entries and settings are untouched.
enum UITestMock {
    static let isActive = ProcessInfo.processInfo.arguments.contains("--uitest-mock-github")

    /// Opens the popover shortly after launch. Synthesized menu bar clicks are
    /// unreliable (fullscreen spaces, crowded menu bars, the notch), so UI
    /// tests use this instead of clicking the status item; togglePopover() is
    /// the same code path the click handler runs.
    static let shouldAutoOpenPopover = ProcessInfo.processInfo.arguments.contains("--uitest-open-popover")

    /// Number of unread notifications initially served by the mock. Two digits,
    /// so marking one as done changes the tray count's rendered width (10 → 9).
    static let notificationCount = 10

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
        defaults.set(false, forKey: "showAccountHeader")
        defaults.set(3600.0, forKey: "fetchInterval")
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
        if method == "GET", path.hasSuffix("/releases/latest") {
            // The update checker's feed: no releases → the checker stays idle.
            return (404, Data())
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
            [
                "id": String(1000 + id),
                "unread": true,
                "reason": "subscribed",
                // Fixed timestamps keep ordering stable across refetches.
                "updated_at": String(format: "2026-08-01T00:00:%02dZ", id),
                "last_read_at": NSNull(),
                "subject": [
                    // A nil subject URL keeps enrichment and web-open resolution inert.
                    "title": "Mock notification #\(id)",
                    "url": NSNull(),
                    "latest_comment_url": NSNull(),
                    "type": "Issue",
                ],
                "repository": [
                    "id": 1,
                    "full_name": "gitify/mock-repo",
                    "html_url": "https://github.com/gitify/mock-repo",
                    "owner": [
                        "login": "gitify",
                        "avatar_url": "https://example.invalid/avatar.png",
                    ],
                ],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: items)
    }
}
