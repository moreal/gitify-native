import Foundation
import Combine

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

enum GroupBy: String, CaseIterable, Identifiable {
    case repository, date
    var id: String { rawValue }
}

/// Color vision mode, independent of light/dark (Gitify's *_COLORBLIND /
/// *_TRITANOPIA theme variants collapse into this orthogonal axis).
enum ColorMode: String, CaseIterable, Identifiable {
    case normal
    /// Protanopia & deuteranopia (red-green).
    case colorblind
    /// Tritanopia (blue-yellow).
    case tritanopia
    var id: String { rawValue }
}

/// UserDefaults-backed app settings. Keys and defaults mirror Gitify's
/// (gitify/src/renderer/stores/defaults.ts) where applicable.
@MainActor
final class SettingsStore: ObservableObject {
    /// Only notifications the user directly participates in (`participating` API param).
    @Published var participating: Bool { didSet { save() } }
    /// Also fetch read notifications (`all` API param).
    @Published var fetchReadNotifications: Bool { didSet { save() } }
    /// Enrich PR/Issue notifications with state (colored icons, numbers, deep links).
    @Published var detailedNotifications: Bool { didSet { save() } }
    @Published var markAsDoneOnOpen: Bool { didSet { save() } }
    @Published var markAsDoneOnUnsubscribe: Bool { didSet { save() } }
    @Published var showNotificationBanners: Bool { didSet { save() } }
    @Published var playSound: Bool { didSet { save() } }
    /// 0–100, Gitify default 20.
    @Published var notificationVolume: Double { didSet { save() } }
    @Published var showCountInTray: Bool { didSet { save() } }
    @Published var useUnreadActiveIcon: Bool { didSet { save() } }
    /// White idle icon instead of the template icon (for wallpaper-tinted menu bars).
    @Published var useAlternateIdleIcon: Bool { didSet { save() } }
    @Published var openAtStartup: Bool { didSet { save() } }
    /// Global open-Gitify hotkey enabled.
    @Published var keyboardShortcut: Bool { didSet { save() } }
    /// The open-Gitify accelerator (default ⌘⇧G).
    @Published var openGitifyShortcut: HotKeyAccelerator { didSet { save() } }
    /// Hotkey registration failure surfaced by the app delegate; not persisted.
    @Published var hotKeyError: String?
    /// Polling interval in seconds. Gitify: default 60, min 60, max 3600.
    @Published var fetchInterval: TimeInterval { didSet { save() } }
    /// Device Flow OAuth client ID. Defaults to Gitify's public development client ID.
    @Published var oauthClientID: String { didSet { save() } }
    @Published var theme: AppTheme { didSet { save() } }
    @Published var colorMode: ColorMode { didSet { save() } }
    @Published var groupBy: GroupBy { didSet { save() } }
    /// Show account section headers even with a single account.
    @Published var showAccountHeader: Bool { didSet { save() } }

    static let defaultOAuthClientID = "Ov23liQIkFs5ehQLNzHF"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        participating = defaults.object(forKey: "participating") as? Bool ?? false
        fetchReadNotifications = defaults.object(forKey: "fetchReadNotifications") as? Bool ?? false
        detailedNotifications = defaults.object(forKey: "detailedNotifications") as? Bool ?? true
        markAsDoneOnOpen = defaults.object(forKey: "markAsDoneOnOpen") as? Bool ?? false
        markAsDoneOnUnsubscribe = defaults.object(forKey: "markAsDoneOnUnsubscribe") as? Bool ?? false
        showNotificationBanners = defaults.object(forKey: "showNotificationBanners") as? Bool ?? true
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        notificationVolume = defaults.object(forKey: "notificationVolume") as? Double ?? 20
        showCountInTray = defaults.object(forKey: "showCountInTray") as? Bool ?? true
        useUnreadActiveIcon = defaults.object(forKey: "useUnreadActiveIcon") as? Bool ?? true
        useAlternateIdleIcon = defaults.object(forKey: "useAlternateIdleIcon") as? Bool ?? false
        openAtStartup = defaults.object(forKey: "openAtStartup") as? Bool ?? false
        keyboardShortcut = defaults.object(forKey: "keyboardShortcut") as? Bool ?? true
        if let keyCode = defaults.object(forKey: "openGitifyShortcut.keyCode") as? Int,
           let modifiers = defaults.object(forKey: "openGitifyShortcut.modifiers") as? Int {
            openGitifyShortcut = HotKeyAccelerator(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        } else {
            openGitifyShortcut = .default
        }
        fetchInterval = max(60, defaults.object(forKey: "fetchInterval") as? TimeInterval ?? 60)
        oauthClientID = defaults.string(forKey: "oauthClientID") ?? Self.defaultOAuthClientID
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        colorMode = ColorMode(rawValue: defaults.string(forKey: "colorMode") ?? "") ?? .normal
        groupBy = GroupBy(rawValue: defaults.string(forKey: "groupBy") ?? "") ?? .repository
        showAccountHeader = defaults.object(forKey: "showAccountHeader") as? Bool ?? false
    }

    private func save() {
        defaults.set(participating, forKey: "participating")
        defaults.set(fetchReadNotifications, forKey: "fetchReadNotifications")
        defaults.set(detailedNotifications, forKey: "detailedNotifications")
        defaults.set(markAsDoneOnOpen, forKey: "markAsDoneOnOpen")
        defaults.set(markAsDoneOnUnsubscribe, forKey: "markAsDoneOnUnsubscribe")
        defaults.set(showNotificationBanners, forKey: "showNotificationBanners")
        defaults.set(playSound, forKey: "playSound")
        defaults.set(notificationVolume, forKey: "notificationVolume")
        defaults.set(showCountInTray, forKey: "showCountInTray")
        defaults.set(useUnreadActiveIcon, forKey: "useUnreadActiveIcon")
        defaults.set(useAlternateIdleIcon, forKey: "useAlternateIdleIcon")
        defaults.set(openAtStartup, forKey: "openAtStartup")
        defaults.set(keyboardShortcut, forKey: "keyboardShortcut")
        defaults.set(Int(openGitifyShortcut.keyCode), forKey: "openGitifyShortcut.keyCode")
        defaults.set(Int(openGitifyShortcut.modifiers), forKey: "openGitifyShortcut.modifiers")
        defaults.set(fetchInterval, forKey: "fetchInterval")
        defaults.set(oauthClientID, forKey: "oauthClientID")
        defaults.set(theme.rawValue, forKey: "theme")
        defaults.set(colorMode.rawValue, forKey: "colorMode")
        defaults.set(groupBy.rawValue, forKey: "groupBy")
        defaults.set(showAccountHeader, forKey: "showAccountHeader")
    }
}
