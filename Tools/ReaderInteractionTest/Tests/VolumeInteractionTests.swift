import XCTest

final class VolumeInteractionTests: XCTestCase {
    func testSlideKeepsVolumePage() { checkPaged("slide") }
    func testCurlKeepsVolumePage() { checkPaged("curl") }

    private func checkPaged(_ mode: String) {
        continueAfterFailure = false
        let app = launch(mode)
        expect(app, entry: 0, volume: false)
        point(app, 0.91, 0.56).tap()
        expect(app, entry: 1, volume: true)
        XCTAssertTrue(app.staticTexts["volume-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["volume-title"].label, "第二卷 风起")
        point(app, 0.91, 0.56).tap()
        expect(app, entry: 2, volume: false)
        point(app, 0.09, 0.56).tap()
        expect(app, entry: 1, volume: true)
        XCTAssertEqual(app.staticTexts["volume-title"].label, "第二卷 风起")
    }

    func testScrollKeepsVolumeTitle() {
        let app = launch("scroll")
        expect(app, entry: 0, volume: false)
        swipe(app)
        expect(app, entry: 1, volume: true)
        XCTAssertTrue(app.staticTexts["volume-title"].waitForExistence(timeout: 5))
        swipe(app)
        expect(app, entry: 2, volume: false)
    }
    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--volume-mode=\(mode)"]
        app.launch()
        return app
    }
    private func expect(_ app: XCUIApplication, entry: Int, volume: Bool) {
        let state = app.staticTexts["volume-state"]
        let predicate = NSPredicate(format: "label == %@", "entry=\(entry);volume=\(volume)")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: state)], timeout: 8), .completed)
    }
    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    private func swipe(_ app: XCUIApplication) {
        point(app, 0.5, 0.65).press(forDuration: 0.03, thenDragTo: point(app, 0.5, 0.20))
    }
}
