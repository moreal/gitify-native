import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// Reconciles the user's launch-at-login preference with macOS state.
/// A pending approval is already registered, so enabling it again is a no-op.
@MainActor
final class LoginItemController {
    private let service: LoginItemService

    init(service: LoginItemService = SMAppService.mainApp) {
        self.service = service
    }

    func reconcile(enabled: Bool) throws {
        switch (enabled, service.status) {
        case (true, .notRegistered):
            try service.register()
        case (false, .enabled), (false, .requiresApproval):
            try service.unregister()
        default:
            break
        }
    }
}
