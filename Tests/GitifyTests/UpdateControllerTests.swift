import XCTest
@testable import Gitify

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testNormalLaunchStartsUpdater() {
        XCTAssertTrue(UITestMock.shouldStartUpdater(
            isUITestActive: false,
            isUnitTestActive: false
        ))
    }

    func testUITestLaunchDoesNotStartUpdater() {
        XCTAssertFalse(UITestMock.shouldStartUpdater(isUITestActive: true))
    }

    func testUnitTestLaunchDoesNotStartUpdater() {
        XCTAssertFalse(UITestMock.shouldStartUpdater(
            isUITestActive: false,
            isUnitTestActive: true
        ))
    }

    func testSupportsGentleScheduledUpdateReminders() {
        let controller = UpdateController(startingUpdater: false)

        XCTAssertTrue(controller.supportsGentleScheduledUpdateReminders)
    }
}
