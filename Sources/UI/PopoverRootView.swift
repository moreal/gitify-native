import SwiftUI

enum PopoverRoute {
    case notifications
    case settings
    case filters
    case login
}

struct PopoverRootView: View {
    @EnvironmentObject private var accountsStore: AccountsStore
    @State private var route: PopoverRoute = .notifications

    var body: some View {
        Group {
            if !accountsStore.isAuthenticated {
                LoginView()
            } else {
                switch route {
                case .notifications:
                    NotificationsListView(
                        onOpenSettings: { route = .settings },
                        onOpenFilters: { route = .filters }
                    )
                case .settings:
                    SettingsView(
                        onClose: { route = .notifications },
                        onAddAccount: { route = .login }
                    )
                case .filters:
                    FiltersView(onClose: { route = .notifications })
                case .login:
                    LoginView(
                        onComplete: { route = .notifications },
                        onCancel: { route = .settings }
                    )
                }
            }
        }
        .frame(width: 420, height: 560)
    }
}
