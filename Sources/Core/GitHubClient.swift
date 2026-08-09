import Foundation

struct GitHubAPIError: LocalizedError {
    let statusCode: Int
    let message: String

    var errorDescription: String? { "GitHub API \(statusCode): \(message)" }
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
        let (data, response) = try await Self.session.data(for: request)
        let http = response as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubAPIError(statusCode: http.statusCode, message: message ?? "request failed")
        }
        return (data, http)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send(request("GET", path, query: query))
        return try Self.decoder.decode(T.self, from: data)
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

    func notifications(participating: Bool, includeRead: Bool) async throws -> [GHNotification] {
        var all: [GHNotification] = []
        for page in 1...10 {
            let pageItems: [GHNotification] = try await get("notifications", query: [
                URLQueryItem(name: "all", value: String(includeRead)),
                URLQueryItem(name: "participating", value: String(participating)),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ])
            all.append(contentsOf: pageItems)
            if pageItems.count < 100 { break }
        }
        return all
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
