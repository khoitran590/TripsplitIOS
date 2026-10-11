import XCTest

@MainActor
final class OnboardingUITests: XCTestCase {
    private var app: XCUIApplication!
    private let tripCard = "trip-card-D2000000-0000-0000-0000-000000000001"

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-ui-test-clear-invitation", "-AppleLanguages", "(en)"] + extra
        app.launch()
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func tap(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<10 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    func testInterruptedIdentityCanResumeAfterRelaunch() {
        launch(["-ui-test-reset-setup", "-ui-test-new-user-onboarding"])
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        capture("Onboarding-identity-light")
        name.tap()
        let original = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + "Maya")
        app.buttons["Finish later"].tap()
        XCTAssertTrue(app.buttons["Continue setup"].waitForExistence(timeout: 5))
        app.terminate()
        launch()
        tap(app.buttons["Continue setup"])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Maya")
        app.buttons["Skip setup"].tap()
        XCTAssertTrue(app.buttons["Explore"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Continue setup"].exists)
    }

    func testProfileSaveAdvancesImmediatelyAndShowsRetry() {
        launch(["-ui-test-reset-setup", "-ui-test-new-user-onboarding"])
        let name = app.textFields["Your name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.tap()
        let original = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + "Maya")
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Create your first trip")).firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry profile sync"].waitForExistence(timeout: 3))
        capture("Onboarding-P2-local-profile-save")
    }

    func testPermanentGuideEntryAndTaskReview() {
        launch(["-ui-test-reset-setup", "-ui-test-returning-user"])
        app.buttons["Quick refresher"].tap()
        app.buttons["Done"].tap()
        tap(app.buttons["Trips"])
        tap(app.buttons["Quick guide"])
        tap(app.buttons["Create or join a trip"])
        tap(app.buttons["I've reviewed this task"])
        XCTAssertTrue(app.buttons["Task reviewed"].exists)
        XCTAssertFalse(app.buttons["Task reviewed"].isEnabled)
        capture("Onboarding-P2-reviewed-task")
    }

    func testPracticeReceiptAndRepaymentKeepRealTrips() {
        launch(["-ui-test-reset-setup", "-ui-test-new-user-onboarding", "-ui-test-quick-start"])
        XCTAssertTrue(app.staticTexts["Ready to dive in?"].waitForExistence(timeout: 8))
        capture("Onboarding-quick-start-light")
        tap(app.buttons["How TripSplit works"])
        XCTAssertTrue(app.staticTexts["Build trips with friends"].waitForExistence(timeout: 5))
        capture("Onboarding-optional-overview-light")
        app.buttons["Skip"].tap()
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Try a practice trip")).firstMatch)
        XCTAssertTrue(app.navigationBars["Practice trip"].waitForExistence(timeout: 5))
        app.buttons["Load sample receipt"].tap()
        capture("Onboarding-practice-receipt-light")
        tap(app.buttons["Save practice expense"])
        XCTAssertTrue(app.staticTexts["practice-expense-saved"].waitForExistence(timeout: 5))
        tap(app.buttons["Confirm practice repayment"].firstMatch)
        XCTAssertTrue(app.staticTexts["Practice repayment confirmed"].firstMatch.exists)
        app.buttons["Exit practice"].tap()
        tap(app.buttons["Trips"])
        XCTAssertTrue(app.buttons[tripCard].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Practice weekend"].exists)
    }

    func testReturnRefresherOpensRealExpenseAction() {
        launch(["-ui-test-reset-setup", "-ui-test-returning-user"])
        XCTAssertTrue(app.buttons["Quick refresher"].waitForExistence(timeout: 8))
        capture("Onboarding-return-card-light")
        app.buttons["Quick refresher"].tap()
        XCTAssertTrue(app.navigationBars["Quick guide"].waitForExistence(timeout: 5))
        capture("Onboarding-quick-guide-light")
        tap(app.buttons["Add and split an expense"])
        tap(app.buttons["Add an expense"])
        XCTAssertTrue(app.navigationBars["Add Expense"].waitForExistence(timeout: 5))
        capture("Onboarding-guide-expense-action-light")
    }

    func testOrganizerCreatesFirstExpenseAndOpensBalances() {
        launch(["-ui-test-reset-setup", "-ui-test-new-user-onboarding", "-ui-test-quick-start", "-ui-test-empty-trips"])
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Create your first trip")).firstMatch)
        let tripName = app.textFields["Summer in Tokyo"]
        XCTAssertTrue(tripName.waitForExistence(timeout: 5))
        tripName.tap()
        tripName.typeText("First weekend\n")
        let friend = app.textFields["Add tripmate name"]
        tap(friend)
        friend.typeText("Jamie\n")
        tap(app.buttons["Start planning"])
        XCTAssertTrue(app.staticTexts["Your first shared expense"].waitForExistence(timeout: 8))
        tap(app.buttons["Add your first expense"])
        let amount = app.textFields["expense-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("60")
        app.textFields["expense-title"].tap()
        app.textFields["expense-title"].typeText("First dinner")
        app.buttons["Done"].tap()
        tap(app.buttons["expense-split"])
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pay for others")).firstMatch)
        tap(app.buttons["save-expense"])
        XCTAssertTrue(app.buttons["Expense saved — add another"].waitForExistence(timeout: 5))
        tap(app.buttons["See who owes what"])
        XCTAssertTrue(app.navigationBars["All balances"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Jamie")).firstMatch.exists)
    }

    func testReturnGuideAtLargestTextAndDarkAppearance() throws {
        launch(["-ui-test-reset-setup", "-ui-test-returning-user",
                "-appearancePreference", "dark", "-ui-test-appearance", "dark",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["Quick refresher"].waitForExistence(timeout: 8))
        capture("Onboarding-return-card-dark-AX5")
        tap(app.buttons["Quick refresher"])
        XCTAssertTrue(app.navigationBars["Quick guide"].waitForExistence(timeout: 5))
        capture("Onboarding-quick-guide-dark-AX5")
        tap(app.buttons["Understand balances and repay"])
        capture("Onboarding-balances-guide-dark-AX5")
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion, .sufficientElementDescription])
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Quick guide"].exists)
    }

    func testLaunchInvitationOffersAuthenticationDirectly() {
        app.launchArguments = ["-ui-test-reset-onboarding", "-ui-test-clear-invitation", "-ui-test-invite-url",
                               "tripsplit://invite?token=0123456789abcdef0123456789abcdef01234567"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sign in or create an account to join this trip."].exists)
        XCTAssertFalse(app.alerts["Sign In to Join the Trip"].exists)
        capture("Onboarding-invitation-auth-light")
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.buttons["Continue invitation"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-test-skip-onboarding"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 8))
        app.buttons["Not now"].tap()
        app.buttons["Dismiss invitation reminder"].tap()
        XCTAssertFalse(app.buttons["Continue invitation"].exists)
    }
}
