import SwiftUI
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    let onClose: () -> Void
    let onAddAccount: () -> Void

    @StateObject private var shortcutRecorder = ShortcutRecorder()
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            PopoverHeader("Settings", onBack: onClose)

            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) {
                        Text("System").tag(AppTheme.system)
                        Text("Light").tag(AppTheme.light)
                        Text("Dark").tag(AppTheme.dark)
                    }
                    Picker("Color mode", selection: $settings.colorMode) {
                        Text("Normal").tag(ColorMode.normal)
                        Text("Colorblind (red/green)").tag(ColorMode.colorblind)
                        Text("Tritanopia (blue/yellow)").tag(ColorMode.tritanopia)
                    }
                    Picker("Group by", selection: $settings.groupBy) {
                        Text("Repository").tag(GroupBy.repository)
                        Text("Date").tag(GroupBy.date)
                    }
                    Toggle("Always show account header", isOn: $settings.showAccountHeader)
                    Toggle("Wrap notification titles", isOn: $settings.wrapNotificationTitle)
                    Toggle("Show issue/PR numbers", isOn: $settings.showNumber)
                }
                Section("Notifications") {
                    Toggle("Only participating", isOn: $settings.participating)
                    Toggle("Fetch read notifications too", isOn: $settings.fetchReadNotifications)
                    Toggle("Fetch all notifications (every page)", isOn: $settings.fetchAllNotifications)
                    Toggle("Detailed notifications (state colors, numbers)", isOn: $settings.detailedNotifications)
                    Toggle("Mark as done when opening", isOn: $settings.markAsDoneOnOpen)
                    Toggle("Mark as done when unsubscribing", isOn: $settings.markAsDoneOnUnsubscribe)
                    Stepper(value: $settings.fetchIntervalMinutes, in: 1...60) {
                        LabeledContent("Fetch interval", value: "\(settings.fetchIntervalMinutes) min")
                    }
                }
                Section("System") {
                    Toggle("Show notification banners", isOn: $settings.showNotificationBanners)
                    Toggle("Play sound", isOn: $settings.playSound)
                    if settings.playSound {
                        Slider(value: $settings.notificationVolume, in: 0...100, step: 10) {
                            Text("Volume")
                        }
                    }
                    Toggle("Show count in menu bar", isOn: $settings.showCountInTray)
                    Toggle("Green icon when unread", isOn: $settings.useUnreadActiveIcon)
                    Toggle("White idle icon", isOn: $settings.useAlternateIdleIcon)
                    Toggle("Global shortcut", isOn: $settings.keyboardShortcut)
                        .onChange(of: settings.keyboardShortcut) { _, _ in shortcutRecorder.stop() }
                    if settings.keyboardShortcut {
                        LabeledContent("Shortcut") {
                            Button(shortcutRecorder.isRecording ? "Press ⌘ + key… (Esc cancels)"
                                                                : settings.openGitifyShortcut.display) {
                                toggleShortcutRecording()
                            }
                        }
                    }
                    if let error = settings.hotKeyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color(nsColor: .systemRed))
                    }
                    Toggle("Open at login", isOn: $settings.openAtStartup)
                }
                Section("Accounts") {
                    ForEach(accountsStore.accounts) { account in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("@\(account.user.login)")
                                Text(account.hostname)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Sign out") {
                                // The accounts observer in AppDelegate refetches.
                                accountsStore.removeAccount(account)
                            }
                        }
                    }
                    Button("Add account", action: onAddAccount)
                }
                Section {
                    Button("Reset settings…", role: .destructive) {
                        isConfirmingReset = true
                    }
                }
            }
            .alert("Reset settings?", isPresented: $isConfirmingReset) {
                Button("Reset", role: .destructive) { settings.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All settings return to their defaults. Accounts and filters are kept.")
            }
            .formStyle(.grouped)
            // Drop the grouped form's opaque backdrop so the popover material
            // shows through, matching the notifications list surface.
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
        .onDisappear { shortcutRecorder.stop() }
        // Coalesced so a settings reset flipping several at once refetches
        // (or refreshes the tray) exactly once.
        .onChange(of: fetchInputs) { _, _ in refetch() }
        .onChange(of: trayInputs) { _, _ in refreshTray() }
    }

    /// Settings whose change requires refetching notifications.
    private var fetchInputs: [Bool] {
        [
            settings.participating,
            settings.fetchReadNotifications,
            settings.fetchAllNotifications,
            settings.detailedNotifications,
        ]
    }

    /// Settings whose change requires re-rendering the tray icon.
    private var trayInputs: [Bool] {
        [
            settings.showCountInTray,
            settings.useUnreadActiveIcon,
            settings.useAlternateIdleIcon,
        ]
    }

    /// Version link to that tag's release notes + Quit
    /// (upstream SettingsFooter).
    private var footer: some View {
        HStack {
            Button("Gitify v\(Self.appVersion)") {
                let url = URL(string: "https://github.com/moreal/gitify-native/releases/tag/v\(Self.appVersion)")!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .help("View release notes")
            Spacer()
            Button("Quit Gitify") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private func refetch() {
        Task { await notificationsStore.fetch() }
    }

    private func toggleShortcutRecording() {
        if shortcutRecorder.isRecording {
            shortcutRecorder.stop()
        } else {
            settings.hotKeyError = nil
            shortcutRecorder.start { settings.openGitifyShortcut = $0 }
        }
    }

    private func refreshTray() {
        notificationsStore.notifyStateChange()
    }
}

/// Owns the local key monitor that captures a new accelerator
/// (upstream SystemSettings.tsx live recorder). A class so the monitor token
/// has a single unambiguous owner and teardown spot.
@MainActor
final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?

    func start(onCapture: @escaping (HotKeyAccelerator) -> Void) {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.stop()
            } else if let accelerator = HotKeyAccelerator(event: event) {
                onCapture(accelerator)
                self?.stop()
            }
            return nil // swallow keystrokes while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

extension HotKeyAccelerator {
    /// Builds from a recorder key event; nil unless ⌘ is held (the recorder
    /// requires ⌘ plus a non-modifier key — pure modifier presses never
    /// produce keyDown events, so ⌘ presence is the only check needed).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command) else { return nil }
        var mods = UInt32(cmdKey)
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}
