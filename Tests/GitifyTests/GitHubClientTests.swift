import XCTest
@testable import Gitify

final class GitHubClientTests: XCTestCase {
    func testFetchAllFollowsNextLinkAcrossFiftyItemPages() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                let page = Self.page(of: request)
                switch page {
                case 1:
                    return Self.response(request, ids: 1...50, link: "<\(baseURL)/notifications?per_page=50&page=2>; rel=\"next\"")
                case 2:
                    return Self.response(request, ids: 51...100, link: "<\(baseURL)/notifications?per_page=50&page=3>; rel=\"next\"")
                case 3:
                    return Self.response(request, ids: 101...125)
                default:
                    XCTFail("Requested an unexpected page: \(page)")
                    return Self.response(request)
                }
            }

            let result = try await client.notifications(participating: false, includeRead: false, fetchAll: true)

            XCTAssertEqual(result.items.count, 125)
            XCTAssertEqual(result.items.first?.id, "1")
            XCTAssertEqual(result.items.last?.id, "125")
            XCTAssertEqual(Set(result.items.map(\.id)).count, 125)
        }
    }

    func testFetchAllFollowsNextLinkEvenForShortPages() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                if Self.page(of: request) == 1 {
                    return Self.response(request, ids: 1...2, link: "<\(baseURL)/notifications?page=7>; rel=\"next\"")
                }
                XCTAssertEqual(Self.page(of: request), 7, "Follow the URL supplied by the server")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token test-token")
                return Self.response(request, ids: 3...3)
            }

            let result = try await client.notifications(participating: false, includeRead: false, fetchAll: true)

            XCTAssertEqual(result.items.map(\.id), ["1", "2", "3"])
        }
    }

    func testFetchAllStopsOnFullPageWithoutNextLink() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                XCTAssertEqual(Self.page(of: request), 1, "A full final page must not trigger another request")
                return Self.response(request, ids: 1...50, link: "<\(baseURL)/notifications?page=1>; rel=\"prev\"")
            }

            let result = try await client.notifications(participating: false, includeRead: false, fetchAll: true)

            XCTAssertEqual(result.items.count, 50)
        }
    }

    func testFetchAllDisabledReturnsOnlyFirstPage() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                XCTAssertEqual(Self.page(of: request), 1)
                return Self.response(request, ids: 1...50, link: "<\(baseURL)/notifications?page=2>; rel=\"next\"")
            }

            let result = try await client.notifications(participating: false, includeRead: false, fetchAll: false)

            XCTAssertEqual(result.items.count, 50)
        }
    }

    func testNextLinkCanAppearAfterOtherRelations() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                if Self.page(of: request) == 1 {
                    return Self.response(request, ids: 1...1, link:
                        "<\(baseURL)/notifications?page=3>; rel=\"last\", <\(baseURL)/notifications?page=2>; rel=\"next\"")
                }
                XCTAssertEqual(Self.page(of: request), 2)
                return Self.response(request, ids: 2...2)
            }

            let result = try await client.notifications(participating: false, includeRead: false, fetchAll: true)

            XCTAssertEqual(result.items.map(\.id), ["1", "2"])
        }
    }

    func testNotificationRequestUsesSupportedPageSizeAndFilters() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "per_page" }?.value, "50")
                XCTAssertEqual(query.first { $0.name == "all" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "participating" }?.value, "true")
                return Self.response(request)
            }

            let result = try await client.notifications(participating: true, includeRead: true, fetchAll: true)

            XCTAssertTrue(result.items.isEmpty)
            XCTAssertEqual(result.serverPollInterval, 60)
        }
    }

    func testLaterPageFailureIsReportedInsteadOfReturningPartialResults() async throws {
        try await withClient { client, baseURL in
            NotificationsURLProtocol.register(host: baseURL.host!) { request in
                if Self.page(of: request) == 1 {
                    return Self.response(request, ids: 1...50, link: "<\(baseURL)/notifications?page=2>; rel=\"next\"")
                }
                return (Data(#"{"message":"Bad credentials"}"#.utf8), HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
                )!)
            }

            do {
                _ = try await client.notifications(participating: false, includeRead: false, fetchAll: true)
                XCTFail("A later page failure must not silently truncate the results")
            } catch let error as GitHubAPIError {
                XCTAssertEqual(error.kind, .badCredentials)
            }
        }
    }

    private func withClient(_ body: (GitHubClient, URL) async throws -> Void) async throws {
        let baseURL = URL(string: "https://\(UUID().uuidString).example.invalid")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            NotificationsURLProtocol.unregister(host: baseURL.host!)
        }
        try await body(GitHubClient(baseURL: baseURL, token: "test-token", session: session), baseURL)
    }

    private static func page(of request: URLRequest) -> Int {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
    }

    private static func response(
        _ request: URLRequest, ids: ClosedRange<Int>? = nil, link: String? = nil
    ) -> (Data, HTTPURLResponse) {
        let notifications = (ids.map(Array.init) ?? []).map { id in
            GHNotification(
                id: String(id), unread: true, reason: "subscribed",
                updatedAt: Date(timeIntervalSince1970: 0), lastReadAt: nil,
                subject: .init(title: "Notification \(id)", url: nil, latestCommentUrl: nil, type: .issue),
                repository: .init(
                    id: 1, fullName: "example/repo", htmlUrl: "https://github.com/example/repo",
                    owner: .init(login: "example", avatarUrl: "https://example.invalid/avatar.png")
                )
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var headers = ["Content-Type": "application/json", "X-Poll-Interval": "60"]
        if let link { headers["Link"] = link }
        return (try! encoder.encode(notifications), HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers
        )!)
    }
}

private final class NotificationsURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Data, HTTPURLResponse)
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    static func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let handler = request.url?.host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
