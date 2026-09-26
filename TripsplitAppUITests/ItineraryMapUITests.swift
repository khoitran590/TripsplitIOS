import XCTest

@MainActor
final class ItineraryMapUITests: XCTestCase {
    func testRouteControlsAreVisibleAndHidingRouteKeepsPins() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-app-store-demo", "-ui-test-skip-onboarding", "-AppleLanguages", "(en)"]
        app.launch()
        app.buttons["Map"].tap()
        XCTAssertTrue(app.buttons["map-optimize-route"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Show stops"].exists)
        let pins = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-itinerary-pin-"))
        XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: 10))
        let count = pins.count
        XCTAssertGreaterThanOrEqual(count, 3)
        XCTAssertTrue(app.staticTexts["Trip places"].exists)
        XCTAssertTrue(app.staticTexts["Choose day"].exists)
        XCTAssertTrue(app.buttons["map-day-picker"].exists)
        app.buttons["map-next-day"].tap()
        XCTAssertTrue(app.buttons["map-day-picker"].label.contains("Day 2 of 2"))
        app.buttons["map-previous-day"].tap()
        XCTAssertTrue(app.buttons["map-day-picker"].label.contains("Day 1 of 2"))
        app.buttons["Show stops"].tap()
        XCTAssertTrue(app.buttons["Hide stops"].exists)
        XCTAssertTrue(app.staticTexts["Optimize reorders flexible stops; timed stops stay put."].exists)
        XCTAssertTrue(app.staticTexts["Tap a stop to review or correct its map pin"].exists)
        app.buttons["map-route-menu"].tap()
        XCTAssertTrue(app.buttons["Retry missing locations"].waitForExistence(timeout: 3))
        app.buttons["Hide route"].tap()
        XCTAssertEqual(pins.count, count)
        XCTAssertTrue(app.buttons["map-optimize-route"].exists)
        app.buttons["map-route-menu"].tap()
        XCTAssertTrue(app.buttons["Show route"].exists)
        app.buttons["Show route"].tap()
        XCTAssertEqual(pins.count, count)
    }
}
