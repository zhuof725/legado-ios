import XCTest

final class TypographyTests: XCTestCase {
    func testNativeCJKColumnsBaselinesAndPagination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--typography-mode"]
        app.launch()
        let inspect = app.buttons["inspect-typography"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.tap()
        let metrics = app.staticTexts["typography-metrics"]
        let ready = NSPredicate { _, _ in metrics.exists && metrics.label.hasPrefix("{") }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: metrics)], timeout: 10), .completed)
        let data = try XCTUnwrap(metrics.label.data(using: .utf8))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        func number(_ key: String) throws -> Double {
            try XCTUnwrap(report[key] as? NSNumber, "Missing \(key): \(metrics.label)").doubleValue
        }
        let detail = XCTAttachment(string: metrics.label)
        detail.name = "production-glyph-metrics"
        detail.lifetime = .keepAlways
        add(detail)
        XCTAssertEqual(report["quoteCorrectFont"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["quoteDistinctGlyphs"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["quoteSourceOK"] as? Bool, true, metrics.label)
        XCTAssertEqual((report["quoteGlyphs"] as? [[String: Any]])?.count, 16, metrics.label)
        // Genuine adjacent Han remains exactly one cell at 19/23/24/26 pt,
        // including nested quotes; never trade a straight right edge for broken words.
        XCTAssertLessThanOrEqual(try number("naturalStepError"), 0.25, metrics.label)
        XCTAssertLessThanOrEqual(try number("naturalEdgeCells"), 2.5, metrics.label)
        XCTAssertGreaterThan(try number("naturalHanPairs"), 70, metrics.label)
        XCTAssertGreaterThan(try number("naturalRows"), 35, metrics.label)
        XCTAssertEqual(try number("naturalTerminalRows"), 16, metrics.label)
        XCTAssertEqual(report["naturalBreaksOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["naturalSourceOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["referenceCompact"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["referencePreserved"] as? Bool, true, metrics.label)
        XCTAssertLessThan(try number("referenceOpeningError"), 0.18, metrics.label)
        XCTAssertGreaterThan(try number("referenceChecks"), 70, metrics.label)
        for key in ["bottomBaselineError", "bottomOverflow", "bottomTopError"] {
            XCTAssertLessThanOrEqual(try number(key), 0.75, "\(key): \(metrics.label)")
        }
        XCTAssertGreaterThan(try number("bottomPages"), 6, metrics.label)
        XCTAssertGreaterThan(try number("bottomContinuations"), 0, metrics.label)
        XCTAssertGreaterThan(try number("bottomComments"), 6, metrics.label)
        XCTAssertEqual(report["bottomTerminalOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["bottomSpecialOK"] as? Bool, true, metrics.label)
        // 首行/续段、全宽标点、不同字号和非整数字号倍数的宽度，实际字形落在同一网格。
        for key in ["gridError", "stepError", "indentError", "edgeError", "tailError", "widthError"] {
            XCTAssertLessThanOrEqual(try number(key), 0.25, "\(key): \(metrics.label)")
        }
        for key in ["scrollWidthError", "scrollGridError"] {
            XCTAssertLessThanOrEqual(try number(key), 0.25, metrics.label)
        }
        XCTAssertLessThanOrEqual(try number("scrollHeightError"), 0.5, metrics.label)
        XCTAssertEqual(try number("scrollParagraphs"), 6, metrics.label)
        XCTAssertGreaterThan(try number("scrollGlyphs"), 100, metrics.label)
        XCTAssertEqual(report["scrollSourceOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["scrollBubbleOK"] as? Bool, true, metrics.label)
        XCTAssertGreaterThan(try number("gridGlyphs"), 1000)
        // 三档字号、三档宽度、0/8/30 行间距，Latin、emoji、气泡不能使某行忽高忽低。
        XCTAssertLessThanOrEqual(try number("baselineError"), 0.5, metrics.label)
        XCTAssertGreaterThan(try number("baselinePairs"), 80)
        XCTAssertLessThanOrEqual(try number("clipping"), 0.5, metrics.label)
        XCTAssertLessThanOrEqual(try number("shapingError"), 0.25, metrics.label)
        XCTAssertEqual(report["nativeRuns"] as? Bool, true, metrics.label)
        XCTAssertEqual(try number("bubbleChecks"), 27, metrics.label)
        XCTAssertEqual(report["bubbleOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(try number("preservationChecks"), 63, metrics.label)
        for key in ["heightError", "paragraphHeightError", "pageOverflow"] {
            XCTAssertLessThanOrEqual(try number(key), 0.5, "\(key): \(metrics.label)")
        }
        XCTAssertEqual(report["offsetsOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(report["sourceOK"] as? Bool, true, metrics.label)
        XCTAssertGreaterThan(try number("continuations"), 0, metrics.label)
        XCTAssertGreaterThan(try number("pages"), 1, metrics.label)
        XCTAssertEqual(try number("commentCount"), 1, metrics.label)
        XCTAssertEqual(report["inkOK"] as? Bool, true, metrics.label)
        XCTAssertEqual(try number("inkChecks"), 27, metrics.label)
        XCTAssertEqual(report["wrappingOK"] as? Bool, true, metrics.label)
        XCTAssertGreaterThan(try number("breakChecks"), 100, metrics.label)
        XCTAssertLessThanOrEqual(try number("bubbleGapError"), 0.25, metrics.label)
        XCTAssertLessThanOrEqual(try number("bubbleBaselineError"), 0.5, metrics.label)
        app.terminate()
        app.launchArguments = ["--typography-mode", "--reference-page"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chapter-title"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reference-production-page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

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
