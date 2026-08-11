import Foundation

/// Failure classes the UI renders distinct error panes for
/// (gitify/src/renderer/utils/core/errors.ts + utils/api/errors.ts).
enum APIErrorKind: Equatable {
    case badCredentials
    case missingScopes
    case rateLimited
    case network
    case unknown
}

struct GitHubAPIError: LocalizedError {
    /// 0 when the request failed before reaching GitHub (transport error).
    let statusCode: Int
    let message: String
    let kind: APIErrorKind

    /// The request never reached GitHub (DNS, timeout, connection loss).
    init(transport: Error) {
        statusCode = 0
        message = transport.localizedDescription
        kind = .network
    }

    init(http: HTTPURLResponse, message: String) {
        statusCode = http.statusCode
        self.message = message
        kind = Self.classify(message: message, http: http)
    }

    var errorDescription: String? {
        statusCode == 0 ? message : "GitHub API \(statusCode): \(message)"
    }

    /// Status/message/header → failure class, mirroring upstream's
    /// determineFailureType (401 → bad credentials; 403/429 → missing scopes
    /// or rate limited; 500 → network).
    private static func classify(message: String, http: HTTPURLResponse) -> APIErrorKind {
        switch http.statusCode {
        case 401:
            return .badCredentials
        case 403, 429:
            if message.contains("Missing the 'notifications' scope") {
                return .missingScopes
            }
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || http.value(forHTTPHeaderField: "Retry-After") != nil
                || message.localizedCaseInsensitiveContains("rate limit") {
                return .rateLimited
            }
            return .unknown
        case 500:
            return .network
        default:
            return .unknown
        }
    }
}

/// Stateless GitHub REST client for a single account.
struct GitHubClient {
    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "gitify-native"]
        // Always hit the network — matches Gitify's Cache-Control: no-cache.
        // A cached /notifications response would show stale data for a poller.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        if UITestMock.isActive {
            config.protocolClasses = [UITestMockURLProtocol.self]
        }
        return URLSession(configuration: config)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let iso8601 = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso8601.date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid ISO8601 date: \(raw)"
                ))
            }
            return date
        }
        return decoder
    }()

    // MARK: - Requests

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw GitHubAPIError(transport: error)
        }
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubAPIError(http: http, message: message ?? "request failed")
        }
        return (data, http)
    }

    // MARK: - User

    /// Returns the authenticated user and the token's OAuth scopes (X-OAuth-Scopes header).
    func authenticatedUser() async throws -> (user: GHUser, scopes: [String]) {
        let (data, http) = try await send(request("GET", "user"))
        let user = try Self.decoder.decode(GHUser.self, from: data)
        let scopes = (http.value(forHTTPHeaderField: "X-OAuth-Scopes") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (user, scopes)
    }

    // MARK: - Notifications

    /// A short page terminates pagination, so this must match `per_page`
    /// below or fetchAll would loop forever.
    private static let notificationsPageSize = 100

    /// fetchAll pages through every result (upstream fetchAllNotifications);
    /// off fetches only the first page. Also reports the server-recommended
    /// minimum poll interval (X-Poll-Interval header), if present.
    func notifications(
        participating: Bool,
        includeRead: Bool,
        fetchAll: Bool
    ) async throws -> (items: [GHNotification], serverPollInterval: TimeInterval?) {
        var all: [GHNotification] = []
        var serverPollInterval: TimeInterval?
        var page = 1
        while true {
            let (data, http) = try await send(request("GET", "notifications", query: [
                URLQueryItem(name: "all", value: String(includeRead)),
                URLQueryItem(name: "participating", value: String(participating)),
                URLQueryItem(name: "per_page", value: String(Self.notificationsPageSize)),
                URLQueryItem(name: "page", value: String(page)),
            ]))
            let pageItems = try Self.decoder.decode([GHNotification].self, from: data)
            if serverPollInterval == nil {
                serverPollInterval = http.value(forHTTPHeaderField: "X-Poll-Interval")
                    .flatMap(TimeInterval.init)
            }
            all.append(contentsOf: pageItems)
            if !fetchAll || pageItems.count < Self.notificationsPageSize { break }
            page += 1
        }
        return (all, serverPollInterval)
    }

    func markThreadRead(id: String) async throws {
        try await send(request("PATCH", "notifications/threads/\(id)"))
    }

    func markThreadDone(id: String) async throws {
        try await send(request("DELETE", "notifications/threads/\(id)"))
    }

    func unsubscribe(threadID: String) async throws {
        try await send(request("PUT", "notifications/threads/\(threadID)/subscription",
                               body: ["ignored": true]))
    }

    /// Fetches an arbitrary API URL returned inside a notification subject
    /// (e.g. the PR/issue the notification points at) as loose JSON.
    func subjectDetail(apiURL: URL) async throws -> [String: Any] {
        var request = URLRequest(url: apiURL)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await send(request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
