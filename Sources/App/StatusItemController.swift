import AppKit
import SwiftUI

/// Owns the NSStatusItem and the popover window. Left click toggles the popover,
/// right click shows a context menu (mirrors Gitify's tray behavior).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settings: SettingsStore
    private let accountsStore: AccountsStore
    private let notificationsStore: NotificationsStore

    init(
        settings: SettingsStore,
        accountsStore: AccountsStore,
        notificationsStore: NotificationsStore
    ) {
        self.settings = settings
        self.accountsStore = accountsStore
        self.notificationsStore = notificationsStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView()
                .environmentObject(settings)
                .environmentObject(accountsStore)
                .environmentObject(notificationsStore)
                .environmentObject(notificationsStore.filters)
        )

        if let button = statusItem.button {
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()
    }

    /// nil follows the system appearance.
    func applyPopoverAppearance(_ appearance: NSAppearance?) {
        popover.appearance = appearance
    }

    // MARK: - Icon

    /// Icon selection mirrors gitify/src/main/handlers/tray.ts: error → red,
    /// unread → green (when enabled), otherwise the template idle icon.
    func refreshIcon() {
        guard let button = statusItem.button else { return }
        let count = notificationsStore.unreadCount
        let idleName = settings.useAlternateIdleIcon ? "tray-idle-white" : "tray-idleTemplate"
        let imageName: String
        switch notificationsStore.trayState {
        case .offline: imageName = "tray-offline"
        case .error: imageName = "tray-error"
        case .active: imageName = settings.useUnreadActiveIcon ? "tray-active" : idleName
        case .idle: imageName = idleName
        }
        let image = NSImage(named: imageName)
        image?.isTemplate = (imageName == "tray-idleTemplate")
        button.image = image

        button.title = (settings.showCountInTray && count > 0) ? " \(count)" : ""
        button.imagePosition = .imageLeft
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
            // Refetch on open, like Gitify's refetch-on-window-focus.
            Task { await notificationsStore.fetch() }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Gitify", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // detach so left click keeps toggling the popover
    }

    @objc private func refresh() {
        Task { await notificationsStore.fetch() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
