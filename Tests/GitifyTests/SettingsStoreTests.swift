import XCTest
@testable import Gitify

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testOpenAtStartupDefaultsToEnabled() {
        withFreshDefaults { defaults in
            XCTAssertTrue(SettingsStore(defaults: defaults).openAtStartup)
        }
    }

    func testOpenAtStartupPreservesStoredFalse() {
        withFreshDefaults { defaults in
            defaults.set(false, forKey: "openAtStartup")

            XCTAssertFalse(SettingsStore(defaults: defaults).openAtStartup)
        }
    }

    func testResetRestoresOpenAtStartupDefault() {
        withFreshDefaults { defaults in
            let settings = SettingsStore(defaults: defaults)
            settings.openAtStartup = false

            settings.reset()

            XCTAssertTrue(settings.openAtStartup)
        }
    }

    private func withFreshDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "SettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
