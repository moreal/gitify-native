import XCTest

/// Regression tests for the menu bar popover.
///
/// The popover is anchored to the status item button. Mutating the button while
/// the popover is open (e.g. the unread-count title shrinking from " 10" to
/// " 9" after mark-as-done) resizes the variable-length status item, and AppKit
/// re-anchors the popover — visible as the popover jumping sideways.
///
/// The app is launched with `--uitest-mock-github`, which serves 10 canned
/// unread notifications from an in-memory mock (see UITestMock.swift) and
/// isolates settings/accounts from the developer's real data.
final class PopoverStabilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest-mock-github"]
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    func testPopoverShowsMockNotifications() {
        let popover = openPopover()
        XCTAssertTrue(
            popover.staticTexts["Mock notification #1"].waitForExistence(timeout: 5),
            "mock notification rows should be listed"
        )
        XCTAssertTrue(
            popover.staticTexts["10"].exists,
            "header badge should show the mock unread count"
        )
    }

    func testPopoverDoesNotMoveWhenMarkingNotificationDone() {
        let popover = openPopover()
        let row = popover.staticTexts["Mock notification #1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "mock notification row should exist")

        let frameBefore = popover.frame

        row.hover()
        let markDone = popover.buttons["notification-mark-done"].firstMatch
        XCTAssertTrue(markDone.waitForExistence(timeout: 3), "hover should reveal the row actions")
        markDone.click()

        // The row disappearing confirms mark-as-done completed and the tray
        // icon refresh (unread count 10 → 9) has been triggered.
        let disappeared = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: row
        )
        wait(for: [disappeared], timeout: 5)
        // Give AppKit a beat to re-anchor the popover if it is going to.
        Thread.sleep(forTimeInterval: 0.5)

        let frameAfter = popover.frame
        XCTAssertEqual(
            frameAfter.origin.x, frameBefore.origin.x, accuracy: 1.0,
            "popover moved horizontally after mark-as-done: \(frameBefore) → \(frameAfter)"
        )
        XCTAssertEqual(
            frameAfter.origin.y, frameBefore.origin.y, accuracy: 1.0,
            "popover moved vertically after mark-as-done: \(frameBefore) → \(frameAfter)"
        )
    }

    // MARK: - Helpers

    private func openPopover() -> XCUIElement {
        var statusItem = app.statusItems["gitify-status-item"]
        if !statusItem.waitForExistence(timeout: 5) {
            statusItem = app.statusItems.firstMatch
            XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "status item should appear in the menu bar")
        }
        statusItem.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "clicking the status item should open the popover")
        return popover
    }
}
