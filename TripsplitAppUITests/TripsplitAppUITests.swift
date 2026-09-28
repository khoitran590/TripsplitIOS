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
        XCTAssertTrue(app.navigationBars["Share a trip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Guide title"].exists)
        XCTAssertTrue(app.textFields["Search city or destination"].exists)
        app.buttons["Next: Things to do"].tap()
        XCTAssertTrue(app.textFields["Search for a place"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add another place"].exists)
        app.buttons["Next: Places to eat"].tap()
        XCTAssertTrue(app.textFields["Search for a restaurant"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add another restaurant"].exists)
        app.buttons["Next: Local tips"].tap()
        app.buttons["Review guide"].tap()
        XCTAssertTrue(app.buttons["Publish to community"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Publish to community"].isEnabled)
        app.buttons["Cancel"].tap()

        let sharedGuide = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Lisbon Like a Local")
        ).firstMatch
        tapAfterScrolling(sharedGuide)
        XCTAssertTrue(app.navigationBars["Lisbon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Use as my starting plan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Community guide options"].exists)

        // The detail section control must work for community guides as well as the
        // bundled editorial guides. Use the explicit identifiers so this test checks
        // the actual tab hit targets rather than an incidental matching label.
        let thingsToDo = app.buttons["curated-guide-section-things-to-do"]
        let restaurants = app.buttons["curated-guide-section-restaurants"]
        XCTAssertTrue(thingsToDo.waitForExistence(timeout: 5))
        XCTAssertTrue(restaurants.exists)
        thingsToDo.tap()
        XCTAssertTrue(app.staticTexts["Recommended locations for this trip"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alfama at sunrise"].exists)
        restaurants.tap()
        XCTAssertTrue(app.staticTexts["Recommended meal picks for this budget"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["O Trevo"].exists)
        captureDesignScreen("Explore-community-guide")
    }

    func testSettingsRowsExposeLabelsValuesAndSelection() throws {
        openDemoSettings()

        // Each row is one control: the title is its label, the trailing text its value.
        let appearance = app.buttons["Appearance & theme"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertEqual(appearance.value as? String, "Light")
        XCTAssertEqual(app.buttons["Language"].value as? String, "English")
        let currency = app.buttons["Home currency"]
        XCTAssertTrue(currency.exists)
        XCTAssertFalse((currency.value as? String ?? "").isEmpty, "Home currency should announce its value")
        // Clipping is audited at the accessibility sizes themselves (next test): the
        // audit's larger-size prediction can't see that rows stack at those sizes.
        try performAccessibilityAudit(for: settingsAuditTypes(contentSize: nil))
        scrollToSettingsBottom()
        try performAccessibilityAudit(for: settingsAuditTypes(contentSize: nil, scrolled: true))

        // Checkmark lists announce their current choice as selected. (Counted within the
        // list: the Profile tab behind the sheet is a selected button too.)
        let selected = NSPredicate(format: "isSelected == true")
        for _ in 0..<12 where !app.buttons["Personal information"].isHittable { app.swipeDown() }
        tapAfterScrolling(app.buttons["Default payment method"])
        XCTAssertTrue(app.navigationBars["Payment method"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.collectionViews.buttons.matching(selected).count, 1, "Exactly one payment method should be selected")
        app.navigationBars["Payment method"].buttons.element(boundBy: 0).tap()

        tapAfterScrolling(app.buttons["Language"])
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.collectionViews.buttons.matching(selected).count, 1, "The current language should be selected")
        app.navigationBars["Language"].buttons.element(boundBy: 0).tap()

        tapAfterScrolling(app.buttons["Appearance & theme"])
        tapAfterScrolling(app.buttons["Typeface"])
        XCTAssertTrue(app.navigationBars["Change fonts"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.collectionViews.buttons.matching(selected).count, 1, "The current font should be selected")
    }

    func testSettingsPagesPushAndReturn() throws {
        openDemoSettings()
        for (row, title) in [("Default payment method", "Payment method"), ("Appearance & theme", "Appearance"),
                             ("Language", "Language"), ("Privacy & AI", "Privacy & AI"),
                             ("Blocked accounts", "Blocked accounts"),
                             ("Community Standards", "Community Standards"), ("Privacy Policy", "Privacy Policy")] {
            tapAfterScrolling(app.buttons[row])
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(row) should push \(title)")
            app.navigationBars[title].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5), "Back from \(title)")
        }
        XCTAssertFalse(app.staticTexts["Featured travel guides"].exists)
        let support = app.buttons["Contact support"]
        for _ in 0..<12 where !support.isHittable { app.swipeUp() }
        XCTAssertTrue(support.isHittable)
        XCTAssertEqual(support.value as? String, "support@tripsplit.app")
    }

    func testSettingsStaysReadableAtLargestTextSizes() throws {
        // The largest standard size (rows stay side by side) and the largest
        // accessibility size (rows stack).
        for size in ["UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            openDemoSettings(contentSize: size)
            captureDesignScreen("Settings-\(size)-top")
            try performAccessibilityAudit(for: settingsAuditTypes(contentSize: size))
            scrollToSettingsBottom()
            captureDesignScreen("Settings-\(size)-bottom")
            try performAccessibilityAudit(for: settingsAuditTypes(contentSize: size, scrolled: true))
        }
    }

    /// - Settings rows switch to a stacked layout at accessibility text sizes. The
    ///   audit's text-clipped check predicts a *larger* size from the current render,
    ///   so below those sizes it flags side-by-side rows that would in fact stack.
    ///   Clipping is asserted only where the stacked layout is actually rendered.
    /// - The audit scrolls the page itself while it runs (a screenshot taken after it
    ///   shows a different offset than one taken before). Started from a scrolled
    ///   state, it reports text straddling the screen edge as clipped, and iOS 26's
    ///   scroll-edge effect — blurred copies of rows under the navigation bar — as
    ///   low-contrast, unlabelled text. Scrolled audits skip those three checks; the
    ///   unscrolled audit covers them, and the colors are also unit tested
    ///   (`testSecondaryTextMeetsContrastInEveryTheme`).
    private func settingsAuditTypes(contentSize: String?, scrolled: Bool = false) -> XCUIAccessibilityAuditType {
        var types = XCUIAccessibilityAuditType.all
        if contentSize?.contains("Accessibility") != true || scrolled { types.subtract(.textClipped) }
        if scrolled { types.subtract([.contrast, .elementDetection]) }
        return types
    }

    private func scrollToSettingsBottom() {
        let footer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Version")).firstMatch
        for _ in 0..<12 where !(footer.exists && footer.isHittable) { app.swipeUp() }
        XCTAssertTrue(footer.isHittable, "Settings footer should be reachable")
        // Let the end-of-content bounce settle: auditing mid-animation measures contrast
        // on pixels the text has already moved away from. (AX frames jump straight to
        // their final position, so they can't be polled for this.)
        usleep(1_500_000)
    }

    private func openDemoSettings(contentSize: String? = nil) {
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-ui-test-theme", "classic",
                               "-appearancePreference", "light", "-AppleLanguages", "(en)"]
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10))
        app.buttons["Profile"].tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
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
