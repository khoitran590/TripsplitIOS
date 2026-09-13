import XCTest

@MainActor
final class ThemeSelectionUITests: XCTestCase {
    func testThemeRowSelectsTheme() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-ui-test-theme", "wabiSabi",
                               "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 10))
        app.buttons["Profile"].tap()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let appearanceRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Appearance & theme")).firstMatch
        XCTAssertTrue(appearanceRow.waitForExistence(timeout: 5))
        appearanceRow.tap()

        let matcha = app.buttons["Matcha"]
        XCTAssertTrue(matcha.waitForExistence(timeout: 5))
        XCTAssertFalse(matcha.isSelected)
        matcha.tap()

        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: matcha)
        waitForExpectations(timeout: 3)
    }
}
