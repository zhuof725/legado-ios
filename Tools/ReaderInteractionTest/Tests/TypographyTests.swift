import XCTest

final class TypographyTests: XCTestCase {
    func testLongChapterTitleIsVisibleAndLayoutControlsPersist() {
        let app = XCUIApplication()
        app.launchArguments = ["--typography-mode"]
        app.launch()
        XCTAssertTrue(app.staticTexts["typography-title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["typography-title"].label.contains("这是一个很长的章节标题"))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.staticTexts["layout-value-font"].waitForExistence(timeout: 5))
        let old = app.staticTexts["layout-value-font"].label
        app.buttons["layout-plus-font"].tap()
        app.buttons["layout-plus-left"].tap()
        XCTAssertNotEqual(app.staticTexts["layout-value-font"].label, old)
        app.buttons["close-settings"].tap()
        app.buttons["open-settings"].tap()
        XCTAssertEqual(app.staticTexts["layout-value-left"].label, "21 pt")
        XCTAssertTrue(app.staticTexts["layout-value-font"].exists)
    }
}
