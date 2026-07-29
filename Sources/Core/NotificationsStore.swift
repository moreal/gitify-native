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
}

@MainActor
final class NotificationsStore: ObservableObject {
    @Published private(set) var groups: [AccountNotifications] = []
    /// Enriched PR/Issue/Discussion detail keyed by notification id.
    @Published private(set) var details: [String: SubjectDetail] = [:]
    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?

    /// Groups after applying the user's filters — what the UI, tray count,
    /// and banners all consume (raw `groups` stays unfiltered, like Gitify's cache).
    var filteredGroups: [AccountNotifications] {
        guard filters.hasActiveFilters else { return groups }
        return groups.map { group in
            AccountNotifications(
                account: group.account,
                notifications: group.notifications.filter {
                    filters.matches($0, detail: details[$0.id], detailedEnabled: settings.detailedNotifications)
                }
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
        if lastError != nil { return .error }
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
    private var seenIDs: Set<String> = []
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
        var fetchError: String?
        for account in accountsStore.accounts {
            guard let client = accountsStore.client(for: account) else { continue }
            do {
                let items = try await client.notifications(
                    participating: settings.participating,
                    includeRead: settings.fetchReadNotifications
                )
                newGroups.append(AccountNotifications(account: account, notifications: items))
            } catch {
                fetchError = "\(account.id): \(error.localizedDescription)"
            }
        }

        lastError = fetchError
        groups = newGroups

        // Enrich before diffing so banners can respect detailed filters (Gitify order).
        if settings.detailedNotifications {
            await enrich(newGroups)
        }

        let currentIDs = Set(newGroups.flatMap(\.notifications).filter(\.unread).map(\.id))
        if hasFetchedOnce {
            let fresh = newGroups.flatMap { group in
                group.notifications
                    .filter { item in
                        item.unread && !seenIDs.contains(item.id)
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
        seenIDs = currentIDs
        hasFetchedOnce = true
    }

    // MARK: - Enrichment

    /// Fetches PR/Issue subject detail for state-colored icons and numbers.
    /// Cached by subject URL + updatedAt so steady-state polls cost no extra requests.
    private func enrich(_ groups: [AccountNotifications]) async {
        var work: [(id: String, url: URL, cacheKey: String, type: SubjectType, client: GitHubClient)] = []
        var enriched: [String: SubjectDetail] = [:]

        for group in groups {
            guard let client = accountsStore.client(for: group.account) else { continue }
            for item in group.notifications {
                // CI subjects have no API URL; their state comes from the title.
                switch item.subject.type {
                case .checkSuite:
                    if let detail = SubjectDetail.parseCheckSuite(
                        title: item.subject.title,
                        repoHtmlUrl: item.repository.htmlUrl
                    ) {
                        enriched[item.id] = detail
                    }
                    continue
                case .workflowRun:
                    if let detail = SubjectDetail.parseWorkflowRun(
                        title: item.subject.title,
                        repoHtmlUrl: item.repository.htmlUrl
                    ) {
                        enriched[item.id] = detail
                    }
                    continue
                default:
                    break
                }
                guard [.pullRequest, .issue, .discussion].contains(item.subject.type),
                      let urlString = item.subject.url,
                      let url = URL(string: urlString)
                else { continue }
                let cacheKey = "\(urlString)|\(item.updatedAt.timeIntervalSince1970)"
                if let cached = detailCache[cacheKey] {
                    enriched[item.id] = cached
                } else {
                    work.append((item.id, url, cacheKey, item.subject.type, client))
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
                    return (item.id, item.cacheKey, SubjectDetail.parse(json: json, type: item.type))
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
        let liveKeys = Set(groups.flatMap(\.notifications).compactMap { item -> String? in
            guard let url = item.subject.url else { return nil }
            return "\(url)|\(item.updatedAt.timeIntervalSince1970)"
        })
        detailCache = detailCache.filter { liveKeys.contains($0.key) }
        details = enriched
    }

    // MARK: - Actions

    func markRead(_ notification: GHNotification, account: Account) async {
        guard let client = accountsStore.client(for: account) else { return }
        try? await client.markThreadRead(id: notification.id)
        removeLocally(notification, account: account)
    }

    func markDone(_ notification: GHNotification, account: Account) async {
        guard let client = accountsStore.client(for: account) else { return }
        do {
            try await client.markThreadDone(id: notification.id)
        } catch {
            // GHES < 3.13 does not support mark-as-done; fall back to mark-as-read.
            try? await client.markThreadRead(id: notification.id)
        }
        removeLocally(notification, account: account)
    }

    func unsubscribe(_ notification: GHNotification, account: Account) async {
        guard let client = accountsStore.client(for: account) else { return }
        try? await client.unsubscribe(threadID: notification.id)
        if settings.markAsDoneOnUnsubscribe {
            await markDone(notification, account: account)
        } else {
            await markRead(notification, account: account)
        }
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
                taskGroup.addTask {
                    do {
                        try await client.markThreadDone(id: item.id)
                    } catch {
                        try? await client.markThreadRead(id: item.id)
                    }
                }
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
        seenIDs.subtract(ids)
        onStateChange?()
    }

    private func removeLocally(_ notification: GHNotification, account: Account) {
        if let index = groups.firstIndex(where: { $0.id == account.id }) {
            groups[index].notifications.removeAll { $0.id == notification.id }
        }
        seenIDs.remove(notification.id)
        onStateChange?()
    }
}
