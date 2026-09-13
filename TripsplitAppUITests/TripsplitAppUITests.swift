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

    func testTripOverviewDestinationsKeepHistoryAndEditingAccessible() throws {
        launchDemoTrip(theme: "classic")

        tapAfterScrolling(app.buttons["trip-members"])
        XCTAssertTrue(app.navigationBars["Members & invitations"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Jamie Chen"].exists)
        XCTAssertTrue(app.textFields["Invite by email"].exists)
        captureDesignScreen("Members")
        app.navigationBars["Members & invitations"].buttons.element(boundBy: 0).tap()

        tapAfterScrolling(app.buttons["trip-expense-history"])
        XCTAssertTrue(app.navigationBars["Expense history"].waitForExistence(timeout: 5))
        let search = app.textFields["Search expenses"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Ramen")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ramen dinner")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Ramen dinner"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textFields["expense-amount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["save-expense"].isEnabled)
        app.buttons["Cancel"].tap()
    }

    func testExpenseDraftCanCreateAndEditFromTripOverview() throws {
        launchDemoTrip(theme: "classic")
        app.buttons["trip-add-expense"].tap()
        let amount = app.textFields["expense-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-expense"].isEnabled)
        amount.tap()
        amount.typeText("12.50")
        let title = app.textFields["expense-title"]
        title.tap()
        title.typeText("Draft regression coffee")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["save-expense"].isEnabled)
        app.buttons["save-expense"].tap()
        XCTAssertTrue(app.buttons["trip-add-expense"].waitForExistence(timeout: 5))

        tapAfterScrolling(app.buttons["trip-expense-history"])
        let search = app.textFields["Search expenses"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Draft regression coffee")
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Draft regression coffee")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Draft regression coffee")
        XCTAssertEqual(Double(amount.value as? String ?? ""), 12.5)
        title.tap()
        title.typeText(" updated")
        app.buttons["Done"].tap()
        app.buttons["save-expense"].tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Draft regression coffee updated")
        XCTAssertEqual(Double(amount.value as? String ?? ""), 12.5)
        app.buttons["Cancel"].tap()
    }

    func testTripOverviewUsesSameDestinationsWithLargeTextAndColonnade() throws {
        launchDemoTrip(theme: "colonnade", largeText: true)
        tapAfterScrolling(app.buttons["trip-all-balances"])
        XCTAssertTrue(app.navigationBars["All balances"].waitForExistence(timeout: 5))
        captureDesignScreen("Balances-large-text")
        app.navigationBars["All balances"].buttons.element(boundBy: 0).tap()
        tapAfterScrolling(app.buttons["trip-itinerary"])
        XCTAssertTrue(app.navigationBars["Tokyo Together"].waitForExistence(timeout: 5))
        captureDesignScreen("Itinerary-large-text")
    }

    func testExploreCommunityGuideAndContributionFrameworkAreReachable() throws {
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-appearancePreference", "light"]
        app.launch()

        let contribute = app.buttons["Contribute"]
        tapAfterScrolling(contribute)
        XCTAssertTrue(app.navigationBars["Community guide"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Guide title"].exists)
        XCTAssertTrue(app.textFields["Search city or destination"].exists)
        XCTAssertTrue(app.textFields["Search for a place"].exists)
        XCTAssertTrue(app.buttons["Add a place"].exists)
        XCTAssertTrue(app.buttons["Add a restaurant"].exists)
        XCTAssertFalse(app.buttons["Publish to community"].isEnabled)
        app.buttons["Cancel"].tap()

        let sharedGuide = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Lisbon Like a Local")
        ).firstMatch
        tapAfterScrolling(sharedGuide)
        XCTAssertTrue(app.navigationBars["Lisbon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use as my starting plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Community guide options"].exists)
        captureDesignScreen("Explore-community-guide")
    }

    private func launchDemoTrip(theme: String, largeText: Bool = false) {
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-ui-test-theme", theme,
                               "-appearancePreference", "light", "-AppleLanguages", "(en)"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Trips"].waitForExistence(timeout: 8))
        app.buttons["Trips"].tap()
        XCTAssertTrue(app.navigationBars["Your trips"].waitForExistence(timeout: 5))
        captureDesignScreen("Trips-" + theme)
        tapAfterScrolling(app.buttons["trip-card-D2000000-0000-0000-0000-000000000001"])
        XCTAssertTrue(app.buttons["trip-add-expense"].waitForExistence(timeout: 5))
        captureDesignScreen("Overview-" + theme)
    }

    private func tapAfterScrolling(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected a reachable control: \(element)")
        element.tap()
    }

    private func captureDesignScreen(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
            // that system-owned clock, so ignore this one false positive. The
            // nil element is the reliable signal that no app-owned control is
            // implicated (app issues always attach their element); the description
            // match stays tolerant of OS/locale phrasing rather than pinning to an
            // exact string that a future Simulator could word differently.
            if !ignoredSimulatorStatusBarContrast,
               issue.element == nil,
               issue.compactDescription.localizedCaseInsensitiveContains("contrast") {
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
