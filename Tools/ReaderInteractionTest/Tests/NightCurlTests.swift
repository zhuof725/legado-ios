import XCTest

final class NightCurlTests: XCTestCase {
    func testNightCurlBackAndFooterSurviveChapterTransition() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chapter-mode=curl-night"]
        app.launch()
        wait(app, chapter: 0, page: 0)
        let title = app.staticTexts["reader-footer-title"]
        let number = app.staticTexts["reader-footer-page"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let initialY = title.frame.midY
        XCTAssertEqual(initialY, number.frame.midY, accuracy: 2)
        tap(app, 0.91, 0.56)
        wait(app, chapter: 0, page: 1)
        XCTAssertEqual(title.frame.midY, initialY, accuracy: 2, "短尾页不能把页脚推上来")
        app.buttons["inspect-animation"].tap()
        let before = app.staticTexts["animation-metrics"].label
        if before != "missing" { XCTAssertTrue(before.contains("double=true;back=28"), before) }
        app.buttons["arm-animation"].tap()
        tap(app, 0.91, 0.56)
        wait(app, chapter: 1, page: 0)
        app.buttons["inspect-animation"].tap()
        let after = app.staticTexts["animation-metrics"].label
        if after != "missing" {
            XCTAssertTrue(after.contains("style=curl;requests=1;ends=1;idle=true;front=0;double=true;back=28"), after)
            XCTAssertFalse(after.contains("frames=0"), "需捕获真正的动画帧而不是只检查章号")
        }
        XCTAssertEqual(title.frame.midY, initialY, accuracy: 2)
        XCTAssertEqual(title.frame.midY, number.frame.midY, accuracy: 2)
        XCTAssertTrue(title.label.contains("第2章"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "night-curl-chapter-completed"
        image.lifetime = .keepAlways
        add(image)
        // 完成后还可以往回翻，不停在背面。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55)).press(forDuration: 0.03,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.55)))
        wait(app, chapter: 0, page: 1)
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
