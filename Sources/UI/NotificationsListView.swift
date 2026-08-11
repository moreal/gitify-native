import SwiftUI

struct NotificationsListView: View {
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var filters: FiltersStore
    let onOpenSettings: () -> Void
    let onOpenFilters: () -> Void

    /// Collapsed account sections (account id) and repository sections
    /// ("accountID|owner/repo"). Session-local like upstream's useState,
    /// though sticky here: a repo that empties and later returns stays
    /// collapsed until the view is recreated.
    @State private var collapsedAccounts: Set<String> = []
    @State private var collapsedRepos: Set<String> = []

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
                            // Only an account whose header (and chevron) is
                            // visible can be collapsed.
                            let isAccountCollapsed = showAccountHeaders
                                && collapsedAccounts.contains(group.id)
                            if showAccountHeaders {
                                AccountHeader(
                                    account: group.account,
                                    hasError: group.error != nil,
                                    isCollapsed: isAccountCollapsed,
                                    onToggleCollapse: { collapsedAccounts.toggle(group.id) }
                                )
                            }
                            if !isAccountCollapsed {
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
    }

    private var showAccountHeaders: Bool {
        accountsStore.accounts.count > 1 || settings.showAccountHeader
    }

    // MARK: - Grouping modes

    private func repositorySections(_ group: AccountNotifications) -> some View {
        // Preserve first-seen repository order, like Gitify's groupNotificationsByRepository.
        var repoOrder: [GHNotification.Repository] = []
        var byRepo: [String: [GHNotification]] = [:]
        for item in group.notifications {
            let key = item.repository.fullName
            if byRepo[key] == nil { repoOrder.append(item.repository) }
            byRepo[key, default: []].append(item)
        }
        return ForEach(repoOrder, id: \.fullName) { repository in
            let collapseKey = "\(group.id)|\(repository.fullName)"
            let isCollapsed = collapsedRepos.contains(collapseKey)
            Section {
                if !isCollapsed {
                    ForEach(byRepo[repository.fullName] ?? []) { item in
                        NotificationRow(notification: item, account: group.account, showRepo: false)
                        Divider().padding(.leading, 12)
                    }
                }
            } header: {
                repoHeader(repository, account: group.account, isCollapsed: isCollapsed) {
                    collapsedRepos.toggle(collapseKey)
                }
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

    // MARK: - Headers

    private func repoHeader(
        _ repository: GHNotification.Repository,
        account: Account,
        isCollapsed: Bool,
        onToggleCollapse: @escaping () -> Void
    ) -> some View {
        HStack {
            AvatarView(url: URL(string: repository.owner.avatarUrl), size: 14)
            Button {
                if let url = URL(string: repository.htmlUrl) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(repository.fullName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open repository")
            Spacer()
            Button {
                Task { await notificationsStore.markRepoDone(fullName: repository.fullName, account: account) }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(.borderless)
            .help("Mark repository as done")
            Button {
                Task { await notificationsStore.markRepoRead(fullName: repository.fullName, account: account) }
            } label: {
                Image(systemName: "eye.slash")
            }
            .buttonStyle(.borderless)
            .help("Mark repository as read")
            sectionCollapseToggle(
                isCollapsed: isCollapsed,
                label: repository.fullName,
                action: onToggleCollapse
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Lightest material that still masks rows scrolling under the pinned
        // header; .bar reads as a heavy chrome strip on the popover material.
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapse)
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

private extension Set {
    /// Membership toggle for the collapse sets.
    mutating func toggle(_ member: Element) {
        if !insert(member).inserted { remove(member) }
    }
}

/// Chevron button toggling a collapsible section — the accessible control;
/// the header row's tap gesture mirrors it for mouse users.
private func sectionCollapseToggle(
    isCollapsed: Bool,
    label: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(isCollapsed ? "Show" : "Hide") notifications for \(label)")
}

/// Account section header: profile-opening avatar, hover quick-links to the
/// host's My issues / My pull requests pages, and the collapse chevron
/// (upstream AccountNotifications header).
private struct AccountHeader: View {
    let account: Account
    let hasError: Bool
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(account.profileURL)
            } label: {
                AvatarView(url: URL(string: account.user.avatarUrl), size: 16)
            }
            .buttonStyle(.plain)
            .help("Open account profile")
            .accessibilityLabel("Open @\(account.user.login)'s profile")
            Text("@\(account.user.login)")
                .font(.subheadline.bold())
            Text(account.hostname)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Stay mounted, fade on hover: inserting them would reflow the
            // header on every hover-in/out (upstream HoverGroup overlays).
            HStack(spacing: 6) {
                quickLink("My issues", icon: "smallcircle.filled.circle", path: "issues")
                quickLink("My pull requests", icon: "arrow.triangle.pull", path: "pulls")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            sectionCollapseToggle(
                isCollapsed: isCollapsed,
                label: "@\(account.user.login)",
                action: onToggleCollapse
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            hasError
                ? Color(nsColor: .systemRed).opacity(0.12)
                : Color.accentColor.opacity(0.08)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleCollapse)
        .onHover { isHovered = $0 }
    }

    private func quickLink(_ help: String, icon: String, path: String) -> some View {
        Button {
            NSWorkspace.shared.open(account.webBaseURL.appending(path: path))
        } label: {
            Image(systemName: icon)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
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
                Text(Self.attributedTitle(notification.subject.title))
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    authorAvatar
                    Text(captionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    /// Renders `backtick`-wrapped title segments as monospace chips
    /// (upstream NotificationTitle + parseInlineCode). Unpaired trailing
    /// backticks are dropped like upstream; empty pairs differ only in
    /// which side of an adjacent chip they attach to.
    private static func attributedTitle(_ title: String) -> AttributedString {
        guard title.contains("`") else { return AttributedString(title) }
        var result = AttributedString()
        let segments = title.components(separatedBy: "`")
        for (index, segment) in segments.enumerated() where !segment.isEmpty {
            // Odd segments sat between backticks; the last one only counts
            // as code if its closing backtick existed.
            let isCode = !index.isMultiple(of: 2) && index < segments.count - 1
            var part = AttributedString(segment)
            if isCode {
                part.font = .system(.caption, design: .monospaced)
                part.backgroundColor = Color(nsColor: .quaternarySystemFill)
            }
            result += part
        }
        // An all-backtick title must not vanish (upstream's no-match fallback).
        return result.characters.isEmpty ? AttributedString(title) : result
    }

    /// Display-user avatar opening their profile; a user-type glyph when
    /// enrichment gave no avatar (upstream NotificationFooter's avatar).
    @ViewBuilder
    private var authorAvatar: some View {
        if let user = detail?.user {
            Button {
                let url = user.htmlUrl.flatMap(URL.init(string:))
                    ?? account.webBaseURL.appending(path: user.login)
                NSWorkspace.shared.open(url)
            } label: {
                AvatarView(
                    url: user.avatarUrl.flatMap(URL.init(string:)),
                    size: 14,
                    fallbackSymbol: userTypeSymbol
                )
            }
            // .plain, not .borderless: borderless accent-tints image labels.
            .buttonStyle(.plain)
            .help(user.login)
            .accessibilityLabel("Open \(user.login)'s profile")
            .accessibilityIdentifier("notification-view-profile")
        } else {
            AvatarView(url: nil, size: 14, fallbackSymbol: userTypeSymbol)
        }
    }

    /// Glyph for the display user; without one, CI subjects read as bots
    /// (upstream display.defaultUserType).
    private var userTypeSymbol: String {
        switch detail?.user?.type {
        case "Bot": return "gearshape.circle"
        case "Organization": return "building.2.crop.circle"
        case nil:
            switch notification.subject.type {
            case .checkSuite, .workflowRun, .repositoryDependabotAlertsThread:
                return "gearshape.circle"
            default:
                return "person.crop.circle"
            }
        default: return "person.crop.circle"
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
