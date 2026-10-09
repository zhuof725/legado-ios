import XCTest

final class NightCurlTests: XCTestCase {
    func testNightCurlBackAndFooterSurviveChapterTransition() {
        let reader = ReaderChecks(self, mode: "curl-night", load: "cached")
        let initial = reader.expect(chapter: 0, page: 0, edges: 0)
        reader.tap(0.91)
        let tail = reader.expect(chapter: 0, page: 1, edges: 0, extra: ["back": "28"])
        XCTAssertEqual(tail.footerY, initial.footerY, accuracy: 2, "短尾页不能把页脚推上来")
        reader.app.buttons["arm-animation"].tap()
        reader.tap(0.91)
        let after = reader.expect(chapter: 1, page: 0, edges: 1,
            extra: ["backMin": "28", "backMax": "28", "backAlpha": "255", "captureError": "none"])
        XCTAssertGreaterThan(Int(after.values["frames"] ?? "0") ?? 0, 0, after.description)
        XCTAssertGreaterThan(Int(after.values["backSamples"] ?? "0") ?? 0, 0, after.description)
        XCTAssertEqual(after.footerY, initial.footerY, accuracy: 2)
        let image = XCTAttachment(screenshot: reader.app.screenshot())
        image.name = "night-curl-chapter-completed"
        image.lifetime = .keepAlways
        add(image)
        reader.drag(from: (0.15, 0.55), to: (0.84, 0.55))
        reader.expect(chapter: 0, page: 1, edges: 2)
        reader.tap(0.10)
        reader.expect(chapter: 0, page: 0, edges: 2)
    }

    private func wait(_ app: XCUIApplication, chapter: Int, page: Int) {
        let p = NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "chapter=\(chapter);page=\(page);", "loading=false", "locked=false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p,
            object: app.staticTexts["chapter-state"])], timeout: 10), .completed)
    }
    private func tap(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
}
