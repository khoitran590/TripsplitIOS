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
        try performAccessibilityAudit()

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
        try performAccessibilityAudit()
    }

    /// Keep the audit strict while making CI failures actionable. XCTest's default
    /// failure only names the category; logging the attached element identifies the
    /// exact control or label that needs correction.
    private func performAccessibilityAudit(
        for auditTypes: XCUIAccessibilityAuditType = .all
    ) throws {
        var issueCount = 0
        var ignoredSimulatorStatusBarContrast = false
        try app.performAccessibilityAudit(for: auditTypes) { issue in
            // iOS 26.5 Simulator reports its own status-bar clock as an unnamed
            // SwiftUI contrast issue. The native XCTest attachment contains only
            // that system-owned clock, so ignore this one nil-element false positive.
            if !ignoredSimulatorStatusBarContrast,
               issue.element == nil,
               issue.compactDescription == "Contrast failed" {
                ignoredSimulatorStatusBarContrast = true
                print("Ignoring simulator status-bar contrast false positive")
                return true
            }
            issueCount += 1
            print("Accessibility audit issue: \(issue.compactDescription)")
            print("Details: \(issue.detailedDescription)")
            print("Element: \(String(describing: issue.element))")
            // Let XCTest continue the scan so one failure doesn't hide the rest.
            // The explicit assertion below keeps every app-owned issue strict.
            return true
        }
        if issueCount > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Accessibility audit failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(issueCount, 0, "Accessibility audit found \(issueCount) issue(s)")
    }
}
