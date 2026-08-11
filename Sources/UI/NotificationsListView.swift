import SwiftUI

struct NotificationsListView: View {
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var filters: FiltersStore
    let onOpenSettings: () -> Void
    let onOpenFilters: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        HStack {
            Text("Notifications")
                .font(.headline)
            if notificationsStore.unreadCount > 0 {
                Text("\(notificationsStore.unreadCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            Spacer()
            if notificationsStore.isFetching {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await notificationsStore.fetch() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            Button(action: onOpenFilters) {
                Image(systemName: filters.hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(filters.hasActiveFilters ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.borderless)
            .help("Filters")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !notificationsStore.isOnline {
            emptyState(
                icon: "wifi.slash",
                title: "Network offline",
                detail: "Your device is offline. Please check your network connection."
            )
        } else if let error = notificationsStore.globalError {
            errorState(error)
        } else {
            let visibleGroups = notificationsStore.filteredGroups
            if visibleGroups.allSatisfy({ $0.notifications.isEmpty && $0.error == nil }) {
                emptyState(
                    icon: "checkmark.circle",
                    title: "All caught up!",
                    detail: filters.hasActiveFilters
                        ? "No notifications match the active filters."
                        : "No new notifications."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(visibleGroups) { group in
                            if showAccountHeaders {
                                accountHeader(group.account, hasError: group.error != nil)
                            }
                            if let error = group.error {
                                inlineErrorBlock(error)
                            } else {
                                switch settings.groupBy {
                                case .repository:
                                    repositorySections(group)
                                case .date:
                                    dateRows(group)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var showAccountHeaders: Bool {
        accountsStore.accounts.count > 1 || settings.showAccountHeader
    }

    // MARK: - Grouping modes

    private func repositorySections(_ group: AccountNotifications) -> some View {
        // Preserve first-seen repository order, like Gitify's groupNotificationsByRepository.
        var repoOrder: [String] = []
        var byRepo: [String: [GHNotification]] = [:]
        for item in group.notifications {
            let key = item.repository.fullName
            if byRepo[key] == nil { repoOrder.append(key) }
            byRepo[key, default: []].append(item)
        }
        return ForEach(repoOrder, id: \.self) { repo in
            Section {
                ForEach(byRepo[repo] ?? []) { item in
                    NotificationRow(notification: item, account: group.account, showRepo: false)
                    Divider().padding(.leading, 12)
                }
            } header: {
                repoHeader(repo, account: group.account)
            }
        }
    }

    private func dateRows(_ group: AccountNotifications) -> some View {
        let sorted = group.notifications.sorted { $0.updatedAt > $1.updatedAt }
        return ForEach(sorted) { item in
            NotificationRow(notification: item, account: group.account, showRepo: true)
            Divider().padding(.leading, 12)
        }
    }

    // MARK: - Headers

    private func accountHeader(_ account: Account, hasError: Bool) -> some View {
        HStack(spacing: 8) {
            AsyncImage(url: URL(string: account.user.avatarUrl)) { image in
                image.resizable()
            } placeholder: {
                Image(systemName: "person.crop.circle")
            }
            .frame(width: 16, height: 16)
            .clipShape(Circle())
            Text("@\(account.user.login)")
                .font(.subheadline.bold())
            Text(account.hostname)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            hasError
                ? Color(nsColor: .systemRed).opacity(0.12)
                : Color.accentColor.opacity(0.08)
        )
    }

    /// Compact in-section error for one failing account, so other accounts'
    /// notifications stay visible (upstream AccountNotifications error block).
    private func inlineErrorBlock(_ error: FetchError) -> some View {
        VStack(spacing: 6) {
            Image(systemName: error.kind.icon)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(error.kind.title)
                .font(.subheadline.bold())
            Text(error.kind.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if error.kind.needsAccountAction {
                Button("Manage accounts", action: onOpenSettings)
                    .controlSize(.small)
                    .tint(Color(nsColor: .systemRed))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private func repoHeader(_ fullName: String, account: Account) -> some View {
        HStack {
            Text(fullName)
                .font(.subheadline.bold())
                .lineLimit(1)
            Spacer()
            Button {
                Task { await notificationsStore.markRepoDone(fullName: fullName, account: account) }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .help("Mark repository as done")
            Button {
                Task { await notificationsStore.markRepoRead(fullName: fullName, account: account) }
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .help("Mark repository as read")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Lightest material that still masks rows scrolling under the pinned
        // header; .bar reads as a heavy chrome strip on the popover material.
        .background(.ultraThinMaterial)
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            accessory()
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ error: FetchError) -> some View {
        emptyState(icon: error.kind.icon, title: error.kind.title, detail: error.kind.guidance) {
            if error.kind == .unknown, !error.message.isEmpty {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if error.kind.needsAccountAction {
                Button("Manage accounts", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .systemRed))
                    .padding(.top, 8)
            }
        }
    }
}

struct NotificationRow: View {
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    @EnvironmentObject private var settings: SettingsStore
    let notification: GHNotification
    let account: Account
    var showRepo = false
    @State private var isHovered = false

    private var detail: SubjectDetail? {
        notificationsStore.details[notification.id]
    }

    private var failure: ActionFailure? {
        notificationsStore.actionFailures[notification.id]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: subjectIcon)
                .foregroundStyle(subjectColor)
                .frame(width: 18)
                .padding(.top, 2)
                .help(notification.subject.type.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.subject.title)
                    .font(.callout)
                    .lineLimit(2)
                Text(captionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            // Keep the buttons visible while a failure is shown so the danger
            // state (and its retry affordance) can't hide with the hover.
            if isHovered || failure != nil {
                HStack(spacing: 6) {
                    actionButton("checkmark", help: "Mark as done", id: "notification-mark-done",
                                 action: .markDone) {
                        await notificationsStore.markDone(notification, account: account)
                    }
                    actionButton("eye.slash", help: "Mark as read", id: "notification-mark-read",
                                 action: .markRead) {
                        await notificationsStore.markRead(notification, account: account)
                    }
                    actionButton("bell.slash", help: "Unsubscribe", id: "notification-unsubscribe",
                                 action: .unsubscribe) {
                        await notificationsStore.unsubscribe(notification, account: account)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { open() }
        .opacity(notification.unread ? 1 : 0.5)
    }

    private func actionButton(
        _ icon: String,
        help: String,
        id: String,
        action: NotificationAction,
        perform: @escaping () async -> Void
    ) -> some View {
        // A recorded failure turns this button into a danger-tinted retry.
        let failedError = failure.flatMap { $0.action == action ? $0.error : nil }
        return Button {
            Task { await perform() }
        } label: {
            Image(systemName: failedError != nil ? "exclamationmark.triangle" : icon)
                .foregroundStyle(failedError != nil ? Color(nsColor: .systemRed) : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(failedError.map { "\(help) failed: \($0.message). Click to retry." } ?? help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }

    private func open() {
        Task {
            let url = await WebURLResolver.url(
                for: notification,
                detail: detail,
                account: account,
                client: accountsStore.client(for: account)
            )
            NSWorkspace.shared.open(url)
            if settings.markAsDoneOnOpen {
                await notificationsStore.markDone(notification, account: account)
            } else {
                await notificationsStore.markRead(notification, account: account)
            }
        }
    }

    private var captionText: String {
        var parts: [String] = []
        if showRepo { parts.append(notification.repository.fullName) }
        if let number = detail?.number { parts.append("#\(number)") }
        parts.append(ReasonLabel.title(for: notification.reason))
        parts.append(notification.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    private var subjectIcon: String {
        switch notification.subject.type {
        case .issue:
            switch detail?.state {
            case .completed, .closed: "checkmark.circle"
            case .notPlanned: "slash.circle"
            default: "smallcircle.filled.circle"
            }
        case .pullRequest:
            detail?.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull"
        case .commit: "circle.dotted"
        case .release: "tag"
        case .discussion:
            detail?.state == .answered || detail?.state == .resolved
                ? "checkmark.bubble" : "bubble.left.and.bubble.right"
        case .checkSuite, .workflowRun:
            switch detail?.state {
            case .success: "checkmark.circle"
            case .failure: "xmark.circle"
            case .cancelled: "stop.circle"
            case .skipped: "slash.circle"
            case .waiting: "hourglass.circle"
            default: "checklist"
            }
        case .repositoryAdvisory, .repositoryVulnerabilityAlert, .repositoryDependabotAlertsThread:
            "shield.lefthalf.filled"
        case .repositoryInvitation: "envelope"
        case .unknown: "bell"
        }
    }

    private var subjectColor: Color {
        StatePalette.color(subjectRole, mode: settings.colorMode)
    }

    /// State → color-role mapping from Gitify's per-type display helpers.
    /// Discussions: open is muted, answered takes the open color, resolved the done color.
    private var subjectRole: StateColorRole {
        if notification.subject.type == .discussion {
            switch detail?.state {
            case .answered: return .open
            case .resolved: return .done
            default: return .muted
            }
        }
        switch detail?.state {
        case .open, .reopened, .success: return .open
        case .closed, .failure: return .closed
        case .completed, .merged: return .done
        case .mergeQueue, .waiting: return .attention
        case .draft, .notPlanned, .cancelled, .skipped,
             nil, .answered, .resolved, .outdated, .duplicate:
            return .muted
        }
    }
}
