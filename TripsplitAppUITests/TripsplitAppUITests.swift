import XCTest

@MainActor
final class TripsplitAppUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testFirstLaunchCanBrowseAndPassesAccessibilityAudit() throws {
        app.launchArguments = ["-ui-test-reset-onboarding"]
        app.launch()

        let browse = app.buttons["Browse without an account"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit()

        browse.tap()
        XCTAssertTrue(app.buttons["Explore"].waitForExistence(timeout: 5))
    }

    func testTopLevelNavigationKeepsEveryLabelVisible() throws {
        app.launchArguments = ["-ui-test-skip-onboarding"]
        app.launch()

        for label in ["Explore", "Map", "Trips", "Profile"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), "Missing \(label) tab")
        }

        app.buttons["Trips"].tap()
        XCTAssertTrue(app.navigationBars["Your trips"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit()
    }
}
