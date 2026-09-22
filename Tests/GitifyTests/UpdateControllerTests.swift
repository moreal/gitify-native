import XCTest
@testable import Gitify

final class UpdateControllerTests: XCTestCase {
    func testNormalLaunchStartsUpdater() {
        XCTAssertTrue(UITestMock.shouldStartUpdater(isUITestActive: false))
    }

    func testUITestLaunchDoesNotStartUpdater() {
        XCTAssertFalse(UITestMock.shouldStartUpdater(isUITestActive: true))
    }
}
