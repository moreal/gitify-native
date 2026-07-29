import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

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
                }
                Section("Notifications") {
                    Toggle("Only participating", isOn: $settings.participating)
                    Toggle("Fetch read notifications too", isOn: $settings.fetchReadNotifications)
                    Toggle("Detailed notifications (state colors, numbers)", isOn: $settings.detailedNotifications)
                    Toggle("Mark as done when opening", isOn: $settings.markAsDoneOnOpen)
                    Toggle("Mark as done when unsubscribing", isOn: $settings.markAsDoneOnUnsubscribe)
                    Picker("Fetch interval", selection: $settings.fetchInterval) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("1 hour").tag(TimeInterval(3600))
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
                        .onChange(of: settings.useAlternateIdleIcon) { _, _ in refreshTray() }
                    Toggle("Open at login", isOn: $settings.openAtStartup)
                        .onChange(of: settings.openAtStartup) { _, enabled in
                            updateLoginItem(enabled: enabled)
                        }
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
                                accountsStore.removeAccount(account)
                                Task { await notificationsStore.fetch() }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: settings.participating) { _, _ in refetch() }
        .onChange(of: settings.fetchReadNotifications) { _, _ in refetch() }
        .onChange(of: settings.detailedNotifications) { _, _ in refetch() }
        .onChange(of: settings.showCountInTray) { _, _ in refreshTray() }
        .onChange(of: settings.useUnreadActiveIcon) { _, _ in refreshTray() }
    }

    private func refetch() {
        Task { await notificationsStore.fetch() }
    }

    private func refreshTray() {
        notificationsStore.notifyStateChange()
    }

    private func updateLoginItem(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Failed to update login item: \(error)")
        }
    }
}
