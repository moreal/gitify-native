import Combine
import Foundation
import Sparkle
import UserNotifications

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    nonisolated static let notificationIdentifier = "gitify-update"

    private var controller: SPUStandardUpdaterController!

    init(startingUpdater: Bool = UITestMock.shouldStartUpdater()) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        if startingUpdater {
            controller.startUpdater()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static var releaseNotesURL: URL {
        URL(string: "https://github.com/moreal/gitify-native/releases/tag/v\(currentVersion)")!
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let content = UNMutableNotificationContent()
        content.title = "Gitify"
        content.body = "Gitify v\(update.displayVersionString) is available."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.notificationIdentifier,
                content: content,
                trigger: nil
            )
        )
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        dismissUpdateNotification()
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        dismissUpdateNotification()
    }

    nonisolated private func dismissUpdateNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: [Self.notificationIdentifier]
        )
    }
}
