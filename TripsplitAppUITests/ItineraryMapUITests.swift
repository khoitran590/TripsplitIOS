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
        XCTAssertTrue(app.buttons["Expand trip controls"].exists)
        let pins = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-itinerary-pin-"))
        XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: 10))
        let count = pins.count
        XCTAssertGreaterThanOrEqual(count, 3)
        app.buttons["map-route-menu"].tap()
        app.buttons["Hide route"].tap()
        XCTAssertEqual(pins.count, count)
        XCTAssertTrue(app.buttons["map-optimize-route"].exists)
        app.buttons["map-route-menu"].tap()
        XCTAssertTrue(app.buttons["Show route"].exists)
        app.buttons["Show route"].tap()
        XCTAssertEqual(pins.count, count)
    }
}
