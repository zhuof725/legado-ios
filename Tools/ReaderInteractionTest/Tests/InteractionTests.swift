import XCTest

final class InteractionTests: XCTestCase {
    func testBubbleTapBeforeAndAfterScrollDoesNotToggleBars() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["locate"].waitForExistence(timeout: 10))
        var points = try locate(in: app)
        coordinate(app, points[0], points[1]).tap()
        XCTAssertEqual(app.staticTexts["counts"].label, "comments=1;bars=0")
        coordinate(app, points[2], points[3]).tap()
        XCTAssertEqual(app.staticTexts["counts"].label, "comments=1;bars=1")

        // Begin the scrolling gesture on the attachment: moving a finger must
        // cancel a tap, not open comments or toggle controls.
        coordinate(app, points[0], points[1]).press(forDuration: 0.02,
            thenDragTo: coordinate(app, points[0], 90))
        XCTAssertEqual(app.staticTexts["counts"].label, "comments=1;bars=1")
        app.scrollViews.firstMatch.swipeUp()
        points = try locate(in: app)
        coordinate(app, points[0], points[1]).tap()
        XCTAssertEqual(app.staticTexts["counts"].label, "comments=2;bars=1")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func coordinate(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }
    private func locate(in app: XCUIApplication) throws -> [Double] {
        app.buttons["locate"].tap()
        let numbers = app.staticTexts["probe"].label.split(separator: ",").prefix(4).compactMap { Double($0) }
        XCTAssertEqual(numbers.count, 4)
        guard numbers.count == 4 else { throw NSError(domain: "NoVisibleBubble", code: 1) }
        return numbers
    }
}
