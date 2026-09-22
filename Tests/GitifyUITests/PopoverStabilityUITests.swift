import AppKit
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
    private var landingScreenshotURL: URL?

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitest-mock-github", "--uitest-open-popover"]
        if name.contains("testCaptureLandingScreenshot") {
            app.launchArguments.append("--uitest-landing-screenshot")
            let url = URL(fileURLWithPath: "/tmp/gitify-popover-\(UUID().uuidString).png")
            try? FileManager.default.removeItem(at: url)
            landingScreenshotURL = url
            app.launchEnvironment["GITIFY_LANDING_SCREENSHOT_PATH"] = url.path
        }
        app.launch()
    }

    override func tearDown() {
        app.terminate()
        app = nil
        if let landingScreenshotURL {
            try? FileManager.default.removeItem(at: landingScreenshotURL)
        }
        landingScreenshotURL = nil
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

    func testCaptureLandingScreenshot() {
        let popover = openPopover()
        XCTAssertTrue(
            popover.staticTexts["Polish the macOS onboarding flow"].waitForExistence(timeout: 5),
            "landing screenshot fixture should show a realistic pull request"
        )
        XCTAssertFalse(
            popover.staticTexts["Mock notification #1"].exists,
            "generic regression fixtures should not appear in the landing screenshot"
        )

        let url = try! XCTUnwrap(landingScreenshotURL)
        let rendered = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: url.path) },
            evaluatedWith: url
        )
        wait(for: [rendered], timeout: 10)

        let representation = try! XCTUnwrap(NSImage(contentsOf: url)?.representations.first)
        XCTAssertEqual(representation.pixelsWide, 1680)
        XCTAssertEqual(representation.pixelsHigh, 2240)
        let bitmap = try! XCTUnwrap(NSBitmapImageRep(data: try! Data(contentsOf: url)))
        var prohibitedSymbolPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.9,
                   color.greenComponent > 0.55,
                   color.blueComponent < 0.2
                {
                    prohibitedSymbolPixels += 1
                }
            }
        }
        XCTAssertEqual(
            prohibitedSymbolPixels, 0,
            "rendered screenshot should not contain SF Symbol prohibition placeholders"
        )
        let fileSize = try! XCTUnwrap(
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
        )
        XCTAssertGreaterThan(
            fileSize.intValue, 100_000,
            "rendered screenshot should contain the full notification list, not an empty view"
        )

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "gitify-popover"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTrayCountUpdatesWithoutMovingPopoverWhenMarkingNotificationDone() {
        let popover = openPopover()
        let statusItem = app.statusItems["gitify-status-item"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Gitify status item should exist")
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
        let countUpdated = expectation(
            for: NSPredicate(format: "title == %@", " 9"),
            evaluatedWith: statusItem
        )
        wait(for: [countUpdated], timeout: 5)
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

    /// The app opens the popover itself via --uitest-open-popover; synthesized
    /// menu bar clicks are too environment-dependent (fullscreen spaces,
    /// crowded menu bars, the notch) to be a stable test fixture.
    private func openPopover() -> XCUIElement {
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 10), "app should auto-open the popover at launch")
        return popover
    }
}
