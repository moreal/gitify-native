import Foundation
import Combine

enum TrayState: Equatable {
    case idle       // no unread notifications
    case active     // unread notifications present
    case error      // last poll failed
    case offline    // no network connectivity
}

/// Per-account notification group shown in the UI.
struct AccountNotifications: Identifiable, Equatable {
    var id: String { account.id }
    let account: Account
    var notifications: [GHNotification]
    /// Set when this account's fetch failed; its section shows an inline
    /// error block while other accounts' notifications stay visible.
    var error: FetchError?
}

/// A classified fetch failure, ready for the UI's per-class error panes.
struct FetchError: Equatable {
    let kind: APIErrorKind
    let message: String

    init(_ error: Error) {
        // The client wraps everything (transport included) in GitHubAPIError;
        // anything else is a local failure like a decode error.
        kind = (error as? GitHubAPIError)?.kind ?? .unknown
        message = error.localizedDescription
    }

    init(kind: APIErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

enum NotificationAction {
    case markRead, markDone, unsubscribe
}

/// A failed row action, kept so the row can show a danger button that retries
/// (upstream useNotificationActionFailuresStore).
struct ActionFailure: Equatable {
    let action: NotificationAction
    let error: FetchError
}

@MainActor
final class NotificationsStore: ObservableObject {
    @Published private(set) var groups: [AccountNotifications] = []
    /// Enriched PR/Issue/Discussion detail keyed by notification id.
    @Published private(set) var details: [String: SubjectDetail] = [:]
    @Published private(set) var isFetching = false
    /// Failed row actions by notification id; cleared on retry or refetch.
    @Published private(set) var actionFailures: [String: ActionFailure] = [:]

    /// Full-pane error, shown only when every account failed: the shared
    /// error if they all failed alike, otherwise a generic unknown
    /// (upstream doesAllAccountsHaveErrors + areAllAccountErrorsSame).
    var globalError: FetchError? {
        guard !groups.isEmpty, groups.allSatisfy({ $0.error != nil }) else { return nil }
        let first = groups[0].error
        return groups.allSatisfy { $0.error == first }
            ? first
            : FetchError(kind: .unknown, message: "")
    }

    /// Groups after applying the user's filters — what the UI, tray count,
    /// and banners all consume (raw `groups` stays unfiltered, like Gitify's cache).
    var filteredGroups: [AccountNotifications] {
        guard filters.hasActiveFilters else { return groups }
        return groups.map { group in
            AccountNotifications(
                account: group.account,
                notifications: group.notifications.filter {
                    filters.matches($0, detail: details[$0.id], detailedEnabled: settings.detailedNotifications)
                },
                error: group.error
            )
        }
    }

    var unreadCount: Int {
        filteredGroups.reduce(0) { $0 + $1.notifications.filter(\.unread).count }
    }

    /// Set by the app's NWPathMonitor; drives the offline icon and pauses polling.
    @Published var isOnline = true {
        didSet {
            guard isOnline != oldValue else { return }
            onStateChange?()
            if isOnline {
                Task { await self.fetch() }
            }
        }
    }

    var trayState: TrayState {
        if !isOnline { return .offline }
        if globalError != nil { return .error }
        return unreadCount > 0 ? .active : .idle
    }

    /// Called with the notifications (and their accounts) that appeared since the previous poll.
    var onNewNotifications: (([(GHNotification, Account)]) -> Void)?
    /// Called whenever unread count / error state changes so the tray icon can update.
    var onStateChange: (() -> Void)?

    private let accountsStore: AccountsStore
    private let settings: SettingsStore
    let filters: FiltersStore
    private var pollTask: Task<Void, Never>?
    /// Unread ids already announced, per account id. Errored accounts keep
    /// their previous set so a transient failure doesn't re-announce every
    /// notification once the account recovers.
    private var seenIDs: [String: Set<String>] = [:]
    private var hasFetchedOnce = false
    /// Subject detail cache keyed by "subjectURL|updatedAt".
    private var detailCache: [String: SubjectDetail] = [:]

    init(accountsStore: AccountsStore, settings: SettingsStore, filters: FiltersStore) {
        self.accountsStore = accountsStore
        self.settings = settings
        self.filters = filters
    }

    // MARK: - Polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                let interval = await self?.settings.fetchInterval ?? 60
                try? await Task.sleep(for: .seconds(max(60, interval)))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Lets settings UI force a tray icon refresh after appearance-related changes.
    func notifyStateChange() {
        onStateChange?()
    }

    func fetch() async {
        guard isOnline else { return }
        guard accountsStore.isAuthenticated else {
            groups = []
            onStateChange?()
            return
        }
        isFetching = true
        defer {
            isFetching = false
            onStateChange?()
        }

        var newGroups: [AccountNotifications] = []
        for account in accountsStore.accounts {
            guard let client = accountsStore.client(for: account) else { continue }
            do {
                let items = try await client.notifications(
                    participating: settings.participating,
                    includeRead: settings.fetchReadNotifications,
                    fetchAll: settings.fetchAllNotifications
                )
                newGroups.append(AccountNotifications(account: account, notifications: items))
            } catch {
                newGroups.append(AccountNotifications(
                    account: account,
                    notifications: [],
                    error: FetchError(error)
                ))
            }
        }

        groups = newGroups
        // Drop failure markers for threads the poll no longer lists.
        if !actionFailures.isEmpty {
            let liveIDs = Set(newGroups.flatMap(\.notifications).map(\.id))
            let kept = actionFailures.filter { liveIDs.contains($0.key) }
            if kept.count != actionFailures.count { actionFailures = kept }
        }
        // Update the tray now; the deferred call re-fires after enrichment.
        onStateChange?()

        // Enrich before diffing so banners can respect detailed filters (Gitify order).
        if settings.detailedNotifications {
            await enrich(newGroups)
        }

        if hasFetchedOnce {
            let fresh = newGroups.flatMap { group in
                group.notifications
                    .filter { item in
                        item.unread && seenIDs[group.id]?.contains(item.id) != true
                            && filters.matches(
                                item,
                                detail: details[item.id],
                                detailedEnabled: settings.detailedNotifications
                            )
                    }
                    .map { ($0, group.account) }
            }
            if !fresh.isEmpty { onNewNotifications?(fresh) }
        }
        for group in newGroups where group.error == nil {
            seenIDs[group.id] = Set(group.notifications.filter(\.unread).map(\.id))
        }
        hasFetchedOnce = true
    }

    // MARK: - Enrichment

    /// Fetches subject detail (state, number, author/display-user) for the
    /// API-enriched subject types — see enrichmentURL. Cached by enrichment
    /// URL + updatedAt so steady-state polls cost no extra requests.
    private func enrich(_ groups: [AccountNotifications]) async {
        var work: [(
            id: String, url: URL, commentURL: URL?, cacheKey: String,
            type: SubjectType, client: GitHubClient
        )] = []
        var enriched: [String: SubjectDetail] = [:]

        for group in groups {
            guard let client = accountsStore.client(for: group.account) else { continue }
            for item in group.notifications {
                // CI subjects have no API URL; their state comes from the title.
                switch item.subject.type {
                case .checkSuite:
                    enriched[item.id] = SubjectDetail.parseCheckSuite(
                        title: item.subject.title,
                        repoHtmlUrl: item.repository.htmlUrl
                    )
                    continue
                case .workflowRun:
                    enriched[item.id] = SubjectDetail.parseWorkflowRun(
                        title: item.subject.title,
                        repoHtmlUrl: item.repository.htmlUrl
                    )
                    continue
                default:
                    break
                }
                guard let cacheKey = Self.cacheKey(for: item),
                      let url = Self.enrichmentURL(for: item).flatMap(URL.init(string:))
                else { continue }
                if let cached = detailCache[cacheKey] {
                    enriched[item.id] = cached
                } else {
                    // Commits additionally fetch the latest comment: its
                    // commenter is the display user (upstream commit.ts).
                    let commentURL = item.subject.type == .commit
                        ? item.subject.latestCommentUrl.flatMap(URL.init(string:))
                        : nil
                    work.append((item.id, url, commentURL, cacheKey, item.subject.type, client))
                }
            }
        }

        let results = await withTaskGroup(
            of: (String, String, SubjectDetail)?.self
        ) { taskGroup -> [(String, String, SubjectDetail)] in
            var collected: [(String, String, SubjectDetail)] = []
            var iterator = work.makeIterator()
            var inFlight = 0
            func addNext(_ group: inout TaskGroup<(String, String, SubjectDetail)?>) {
                guard let item = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    guard let json = try? await item.client.subjectDetail(apiURL: item.url) else {
                        return nil
                    }
                    var detail = SubjectDetail.parse(json: json, type: item.type)
                    if let commentURL = item.commentURL,
                       let commentJson = try? await item.client.subjectDetail(apiURL: commentURL) {
                        detail.applyLatestComment(json: commentJson)
                    }
                    return (item.id, item.cacheKey, detail)
                }
            }
            for _ in 0..<8 { addNext(&taskGroup) }
            while inFlight > 0 {
                guard let result = await taskGroup.next() else { break }
                inFlight -= 1
                if let result { collected.append(result) }
                addNext(&taskGroup)
            }
            return collected
        }

        for (id, cacheKey, detail) in results {
            detailCache[cacheKey] = detail
            enriched[id] = detail
        }
        // Drop cache entries no longer referenced by any current notification.
        let liveKeys = Set(groups.flatMap(\.notifications).compactMap(Self.cacheKey(for:)))
        detailCache = detailCache.filter { liveKeys.contains($0.key) }
        details = enriched
    }

    /// The primary API URL enrichment fetches for a notification, nil for
    /// types that aren't enriched from the API.
    private static func enrichmentURL(for item: GHNotification) -> String? {
        switch item.subject.type {
        case .pullRequest, .issue, .discussion, .commit, .release:
            return item.subject.url
        default:
            return nil
        }
    }

    /// Detail-cache key; must stay in lockstep between the fetch pass and the
    /// liveness cleanup or entries get evicted every poll.
    private static func cacheKey(for item: GHNotification) -> String? {
        enrichmentURL(for: item).map { "\($0)|\(item.updatedAt.timeIntervalSince1970)" }
    }

    // MARK: - Actions

    func markRead(_ notification: GHNotification, account: Account) async {
        await performAction(.markRead, notification, account: account) { client in
            try await client.markThreadRead(id: notification.id)
        }
    }

    func markDone(_ notification: GHNotification, account: Account) async {
        await performAction(.markDone, notification, account: account) { client in
            try await Self.markDoneWithFallback(notification.id, client: client)
        }
    }

    func unsubscribe(_ notification: GHNotification, account: Account) async {
        let markAsDone = settings.markAsDoneOnUnsubscribe
        await performAction(.unsubscribe, notification, account: account) { client in
            try await client.unsubscribe(threadID: notification.id)
            if markAsDone {
                try await Self.markDoneWithFallback(notification.id, client: client)
            } else {
                try await client.markThreadRead(id: notification.id)
            }
        }
    }

    /// GHES < 3.13 does not support mark-as-done; fall back to mark-as-read.
    private static func markDoneWithFallback(_ id: String, client: GitHubClient) async throws {
        do {
            try await client.markThreadDone(id: id)
        } catch {
            try await client.markThreadRead(id: id)
        }
    }

    /// Optimistically removes the thread, then runs the API call; on failure
    /// the thread is restored in place and the failure recorded so the row's
    /// action button turns into a retry affordance.
    private func performAction(
        _ action: NotificationAction,
        _ notification: GHNotification,
        account: Account,
        operation: (GitHubClient) async throws -> Void
    ) async {
        guard let client = accountsStore.client(for: account) else { return }
        removeLocally(ids: [notification.id], accountID: account.id)
        do {
            try await operation(client)
            // A poll racing the action may have resurrected the thread from a
            // stale server snapshot; drop it again now that the action stuck.
            removeLocally(ids: [notification.id], accountID: account.id)
        } catch {
            actionFailures[notification.id] = ActionFailure(action: action, error: FetchError(error))
            restoreLocally(notification, account: account)
        }
    }

    /// Undoes an optimistic removal: reinserts the thread by recency (the
    /// order the API returns) and re-marks it seen so it doesn't re-announce
    /// on the next poll.
    private func restoreLocally(_ notification: GHNotification, account: Account) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == account.id }),
              !groups[groupIndex].notifications.contains(where: { $0.id == notification.id })
        else { return }
        let position = groups[groupIndex].notifications
            .firstIndex { $0.updatedAt < notification.updatedAt }
            ?? groups[groupIndex].notifications.count
        groups[groupIndex].notifications.insert(notification, at: position)
        if notification.unread {
            seenIDs[account.id, default: []].insert(notification.id)
        }
        onStateChange?()
    }

    /// Marks every visible notification of the repo as read via individual thread
    /// calls, matching Gitify (the bulk repo endpoint would also affect filtered-out threads).
    func markRepoRead(fullName: String, account: Account) async {
        guard let client = accountsStore.client(for: account),
              let group = filteredGroups.first(where: { $0.id == account.id })
        else { return }
        let targets = group.notifications.filter { $0.repository.fullName == fullName }
        await withTaskGroup(of: Void.self) { taskGroup in
            for item in targets {
                taskGroup.addTask { try? await client.markThreadRead(id: item.id) }
            }
        }
        removeLocally(ids: Set(targets.map(\.id)), accountID: account.id)
    }

    /// Marks every visible notification of the repo as done (falling back to read
    /// per-thread on GHES < 3.13), mirroring Gitify's RepositoryNotifications action.
    func markRepoDone(fullName: String, account: Account) async {
        guard let client = accountsStore.client(for: account),
              let group = filteredGroups.first(where: { $0.id == account.id })
        else { return }
        let targets = group.notifications.filter { $0.repository.fullName == fullName }
        await withTaskGroup(of: Void.self) { taskGroup in
            for item in targets {
                taskGroup.addTask { try? await Self.markDoneWithFallback(item.id, client: client) }
            }
        }
        removeLocally(ids: Set(targets.map(\.id)), accountID: account.id)
    }

    /// Removes only the given threads locally — filtered-out notifications of the
    /// same repo were not marked on the server and must stay in the cache.
    private func removeLocally(ids: Set<String>, accountID: String) {
        if let index = groups.firstIndex(where: { $0.id == accountID }) {
            groups[index].notifications.removeAll { ids.contains($0.id) }
        }
        seenIDs[accountID]?.subtract(ids)
        if ids.contains(where: { actionFailures[$0] != nil }) {
            actionFailures = actionFailures.filter { !ids.contains($0.key) }
        }
        onStateChange?()
    }
}
