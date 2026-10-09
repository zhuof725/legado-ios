import XCTest

final class NativeReaderTests: XCTestCase {
    func testNativeCurlAndJustifiedText() { checkNative("curl") }
    func testNativeSlideAndJustifiedText() { checkNative("slide") }

    private func checkNative(_ mode: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chapter-mode=\(mode)", "--chapter-load=cached"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chapter-state"].waitForExistence(timeout: 8))
        expect(app, chapter: 0, page: 0, edges: 0)
        app.buttons["inspect-native"].tap()
        let expected = "native=true;transition=\(mode == "curl" ? "curl" : "scroll");double=false;idle=true;alignment=justified;indent=38;continuation=0"
        XCTAssertEqual(app.staticTexts["native-info"].label, expected)

        // 章内手势由 UIKit 自己处理；不通过测试调用生产完成回调。
        drag(app, 0.85, 0.15)
        expect(app, chapter: 0, page: 1, edges: 0)
        drag(app, 0.85, 0.15)
        expect(app, chapter: 1, page: 0, edges: 1)
        drag(app, 0.15, 0.85)
        expect(app, chapter: 0, page: 1, edges: 2)
        tap(app, 0.91)
        expect(app, chapter: 1, page: 0, edges: 3)

        // 同页数内容刷新不得留下旧正文/旧页脚。
        app.buttons["refresh-content"].tap()
        expect(app, chapter: 1, page: 0, edges: 3, revision: 1)
        tap(app, 0.91)
        expect(app, chapter: 1, page: 1, edges: 3, revision: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "native-\(mode)-justified-text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func expect(_ app: XCUIApplication, chapter: Int, page: Int, edges: Int, revision: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line) {
        let state = app.staticTexts["chapter-state"]
        let titles = app.staticTexts.matching(identifier: "reader-footer-title")
        let numbers = app.staticTexts.matching(identifier: "reader-footer-page")
        let prefix = "chapter=\(chapter);page=\(page);edges=\(edges);loading=false"
        let title = "第\(chapter + 1)章，第\(page + 1)页" + (revision == 0 ? "" : " · 更新\(revision)")
        let predicate = NSPredicate { _, _ in
            guard state.exists, state.label.hasPrefix(prefix), state.label.contains("locked=false"),
                  titles.count == 1, numbers.count == 1 else { return false }
            return titles.element(boundBy: 0).label == title && numbers.element(boundBy: 0).label == "\(page + 1)/2"
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: state)], timeout: 6)
        XCTAssertEqual(result, .completed,
            "state=\(state.exists ? state.label : "missing"); footer=\(titles.count == 1 ? titles.element(boundBy: 0).label : "count=\(titles.count)")", file: file, line: line)
    }
    private func point(_ app: XCUIApplication, _ x: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.55))
    }
    private func tap(_ app: XCUIApplication, _ x: CGFloat) { point(app, x).tap() }
    private func drag(_ app: XCUIApplication, _ start: CGFloat, _ end: CGFloat) {
        point(app, start).press(forDuration: 0.03, thenDragTo: point(app, end))
    }
}
