import AppKit
import Carbon.HIToolbox
import Combine
import Network
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private(set) var settings: SettingsStore!
    private(set) var accountsStore: AccountsStore!
    private(set) var filtersStore: FiltersStore!
    private(set) var notificationsStore: NotificationsStore!
    private var statusItemController: StatusItemController!
    private var themeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let defaults: UserDefaults = UITestMock.isActive ? UITestMock.makeDefaults() : .standard
        settings = SettingsStore(defaults: defaults)
        accountsStore = AccountsStore(defaults: defaults)
        filtersStore = FiltersStore(defaults: defaults)
        notificationsStore = NotificationsStore(
            accountsStore: accountsStore,
            settings: settings,
            filters: filtersStore
        )
        statusItemController = StatusItemController(
            settings: settings,
            accountsStore: accountsStore,
            notificationsStore: notificationsStore
        )

        applyTheme(settings.theme)
        themeObserver = settings.$theme.dropFirst().sink { [weak self] theme in
            self?.applyTheme(theme)
        }

        // Fetch immediately when an account is added/removed instead of waiting
        // for the next poll tick.
        accountsObserver = accountsStore.$accounts.dropFirst().sink { [weak self] _ in
            Task { await self?.notificationsStore.fetch() }
        }

        startNetworkMonitor()

        notificationsStore.onStateChange = { [weak self] in
            self?.statusItemController.refreshIcon()
        }
        notificationsStore.onNewNotifications = { [weak self] fresh in
            self?.deliverSystemNotifications(for: fresh)
        }

        if !UITestMock.isActive {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        UNUserNotificationCenter.current().delegate = self

        // Refetch immediately after system wake / screen wake (Gitify: system-wake IPC).
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceCenter.addObserver(
                self,
                selector: #selector(systemDidWake),
                name: name,
                object: nil
            )
        }

        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.statusItemController.togglePopover()
        }

        notificationsStore.startPolling()
    }

    private var hotKey: GlobalHotKey?
    private var accountsObserver: AnyCancellable?
    private let pathMonitor = NWPathMonitor()

    @objc private func systemDidWake() {
        Task { await notificationsStore.fetch() }
    }

    /// Drives the offline tray icon and pauses/resumes polling (Gitify's networkMode).
    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.notificationsStore.isOnline = online
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "gitify.network-monitor"))
    }

    private func applyTheme(_ theme: AppTheme) {
        let appearance: NSAppearance?
        switch theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        // NSPopover inherits appearance from the status bar window, not the app,
        // so it must be set explicitly.
        statusItemController.applyPopoverAppearance(appearance)
    }

    /// Delivered banner identifier → source notification, for click-through.
    private var deliveredBanners: [String: (GHNotification, Account)] = [:]

    /// Mirrors Gitify's native notification behavior: one item → repo/title banner
    /// with click-through; multiple items → a single summary banner.
    private func deliverSystemNotifications(for fresh: [(GHNotification, Account)]) {
        if settings.playSound {
            playBundledSound()
        }
        guard settings.showNotificationBanners else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        let identifier: String

        if fresh.count == 1, let (item, account) = fresh.first {
            identifier = "gitify-\(item.id)"
            deliveredBanners[identifier] = (item, account)
            content.title = item.repository.fullName
            content.body = "\(item.subject.title) [\(item.subject.type.rawValue)]"
        } else {
            identifier = "gitify-batch"
            content.title = "Gitify"
            content.body = "You have \(fresh.count) notifications"
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    private var sound: NSSound?

    private func playBundledSound() {
        guard let url = Bundle.main.url(forResource: "clearly", withExtension: "mp3") else { return }
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = Float(settings.notificationVolume / 100)
        sound?.play()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// Banner clicked: open the notification in the browser (single) or the popover (summary).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        guard let (item, account) = deliveredBanners.removeValue(forKey: identifier) else {
            statusItemController.togglePopover()
            return
        }
        let url = await WebURLResolver.url(
            for: item,
            detail: notificationsStore.details[item.id],
            account: account,
            client: accountsStore.client(for: account)
        )
        NSWorkspace.shared.open(url)
        await notificationsStore.markRead(item, account: account)
    }
}
