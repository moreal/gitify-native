import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init(startingUpdater: Bool = UITestMock.shouldStartUpdater()) {
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    static var releaseNotesURL: URL {
        URL(string: "https://github.com/moreal/gitify-native/releases/tag/v\(currentVersion)")!
    }
}
