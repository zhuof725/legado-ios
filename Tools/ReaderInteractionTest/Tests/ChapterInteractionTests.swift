import XCTest

final class ChapterInteractionTests: XCTestCase {
    func testSlideChapterBoundary() { checkPagedMode("slide") }
    func testCurlChapterBoundary() { checkPagedMode("curl") }
    func testFadeChapterBoundary() { checkPagedMode("fade") }

    private func checkPagedMode(_ mode: String) {
        let reader = ReaderChecks(self, mode: mode, load: "slow")
        reader.expect(chapter: 0, page: 0, edges: 0)
        reader.drag(from: (0.84, 0.55), to: (0.16, 0.55))
        reader.expect(chapter: 0, page: 1, edges: 0) // 到达末页本身不能跳章。
        reader.drag(from: (0.50, 0.75), to: (0.50, 0.45))
        reader.expect(chapter: 0, page: 1, edges: 0)
        reader.drag(from: (0.84, 0.55), to: (0.16, 0.55))
        reader.expect(chapter: 1, page: 0, edges: 1)
        reader.drag(from: (0.16, 0.55), to: (0.84, 0.55))
        reader.expect(chapter: 0, page: 1, edges: 2) // 反向落在上一章末页。
        reader.tap(0.91)
        reader.expect(chapter: 1, page: 0, edges: 3)
        reader.tap(0.91)
        reader.expect(chapter: 1, page: 1, edges: 3)
        reader.tap(0.91)
        reader.expect(chapter: 2, page: 0, edges: 4)
        reader.drag(from: (0.84, 0.55), to: (0.16, 0.55))
        reader.expect(chapter: 2, page: 1, edges: 4)
        reader.drag(from: (0.84, 0.55), to: (0.16, 0.55))
        reader.expect(chapter: 2, page: 1, edges: 4) // 书尾不重开本章。
        reader.drag(from: (0.16, 0.55), to: (0.84, 0.55))
        reader.expect(chapter: 2, page: 0, edges: 4) // 复位必须恢复 dataSource。
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
