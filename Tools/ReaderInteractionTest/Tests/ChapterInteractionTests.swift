import XCTest

final class ChapterInteractionTests: XCTestCase {
    func testSlideChapterBoundary() { checkPagedMode("slide") }
    func testCurlChapterBoundary() { checkPagedMode("curl") }
    func testFadeChapterBoundary() { checkPagedMode("fade") }

    private func checkPagedMode(_ mode: String) {
        let app = launch(mode)
        expect(app, chapter: 0, page: 0, edges: 0)
        app.buttons["inspect-animation"].tap()
        let initialID = app.staticTexts["animation-metrics"].label.components(separatedBy: ";id=").last
        drag(app, from: (0.84, 0.55), to: (0.16, 0.55))
        expect(app, chapter: 0, page: 1, edges: 0) // 到达末页本身不能跳章。
        drag(app, from: (0.50, 0.75), to: (0.50, 0.45))
        expect(app, chapter: 0, page: 1, edges: 0) // 垂直手势不是翻页。
        drag(app, from: (0.84, 0.55), to: (0.16, 0.55))
        expect(app, chapter: 1, page: 0, edges: 1)
        XCTAssertTrue(app.staticTexts["reader-footer-title"].label.contains("第2章"))
        app.buttons["inspect-animation"].tap()
        let metrics = app.staticTexts["animation-metrics"].label
        XCTAssertTrue(metrics.contains("style=\(mode);requests=1;ends=1;idle=true;front=0"), metrics)
        XCTAssertEqual(metrics.components(separatedBy: ";id=").last, initialID)
        // 首屏往回正常翻页，回到上一章的末页。
        drag(app, from: (0.16, 0.55), to: (0.84, 0.55))
        expect(app, chapter: 0, page: 1, edges: 2)
        point(app, 0.91, 0.55).tap()
        expect(app, chapter: 1, page: 0, edges: 3) // 点右侧也能下一章。
        point(app, 0.91, 0.55).tap()
        expect(app, chapter: 1, page: 1, edges: 3)
        point(app, 0.91, 0.55).tap()
        expect(app, chapter: 2, page: 0, edges: 4)
        drag(app, from: (0.84, 0.55), to: (0.16, 0.55))
        expect(app, chapter: 2, page: 1, edges: 4)
        drag(app, from: (0.84, 0.55), to: (0.16, 0.55))
        expect(app, chapter: 2, page: 1, edges: 4) // 书尾不重开本章。
        drag(app, from: (0.16, 0.55), to: (0.84, 0.55))
        expect(app, chapter: 2, page: 0, edges: 4) // 复位必须恢复 dataSource。
    }

    func testScrollAdvancesOnlyAfterUserGesture() {
        let app = launch("scroll")
        expect(app, chapter: 0, page: 0, edges: 0)
        app.buttons["program-bottom"].tap()
        expect(app, chapter: 0, page: 0, edges: 0) // 定位/布局到底不跳章。
        drag(app, from: (0.50, 0.78), to: (0.50, 0.20))
        expect(app, chapter: 1, page: 0, edges: 1)
        // 新章顶部已恢复，旧章惯性不可连续推进新章。
        expect(app, chapter: 1, page: 0, edges: 1)
        app.buttons["program-bottom"].tap()
        drag(app, from: (0.50, 0.78), to: (0.50, 0.20))
        expect(app, chapter: 2, page: 0, edges: 2)
        app.buttons["program-bottom"].tap()
        drag(app, from: (0.50, 0.78), to: (0.50, 0.20))
        expect(app, chapter: 2, page: 0, edges: 2)
    }

    func testShortChapterDoesNotAutoSkipWithoutSwipe() {
        let app = launch("short")
        expect(app, chapter: 0, page: 0, edges: 0)
        drag(app, from: (0.50, 0.60), to: (0.50, 0.22))
        expect(app, chapter: 1, page: 0, edges: 1)
    }

    private func launch(_ mode: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chapter-mode=\(mode)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chapter-state"].waitForExistence(timeout: 10))
        return app
    }
    private func expect(_ app: XCUIApplication, chapter: Int, page: Int, edges: Int) {
        let element = app.staticTexts["chapter-state"]
        let prefix = "chapter=\(chapter);page=\(page);edges=\(edges);loading=false"
        let predicate = NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", prefix, "locked=false")
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 8)
        XCTAssertEqual(result, .completed, "实际状态：\(element.label)")
    }
    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    private func drag(_ app: XCUIApplication, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        point(app, from.0, from.1).press(forDuration: 0.03, thenDragTo: point(app, to.0, to.1))
    }
}
