import XCTest

final class ContinuousScrollTests: XCTestCase {
    func testInlineChapterBoundaryAndStablePrependAppendRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--continuous-scroll-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["scroll-boundary"].waitForExistence(timeout: 10))
        app.buttons["scroll-boundary"].tap()
        let before = try inspect(app)
        XCTAssertEqual(before["native"] as? Bool, true)
        let start = try frame(1, in: before)
        let progress = app.staticTexts["continuous-state"].label
        app.buttons["scroll-prepend"].tap()
        let inserted = try inspect(app)
        XCTAssertEqual(try y(1, in: inserted), try XCTUnwrap(start["y"] as? Double), accuracy: 1)
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("changes=0"))
        app.buttons["scroll-append"].tap()
        let appended = try inspect(app)
        XCTAssertEqual(try y(1, in: appended), try y(1, in: inserted), accuracy: 1)
        app.buttons["scroll-trim"].tap()
        let trimmed = try inspect(app)
        XCTAssertEqual(try y(1, in: trimmed), try y(1, in: inserted), accuracy: 1)
        XCTAssertTrue(progress.contains("changes=0"))

        // 一次真实拖动让章尾与下一章标题同时出现，仍然是同一 UIScrollView。
        drag(app, from: 0.67, to: 0.49)
        let tail = app.staticTexts["scroll-tail-1"]
        let title = app.staticTexts["scroll-title-2"]
        XCTAssertTrue(tail.exists && title.exists)
        let viewport = app.scrollViews["continuous-reader-scroll"].frame
        XCTAssertTrue(tail.frame.intersects(viewport), "上一章末尾应保留在屏幕中")
        XCTAssertTrue(title.frame.intersects(viewport), "下一章标题应接在同一屏中")
        XCTAssertLessThan(tail.frame.maxY, title.frame.minY)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "continuous-two-chapter-boundary"
        image.lifetime = .keepAlways
        add(image)

        let oldProgress = app.staticTexts["continuous-state"].label
        app.buttons["scroll-restore"].tap()
        let restored = try inspect(app)
        let chapter2 = try frame(2, in: restored)
        let height = try XCTUnwrap(chapter2["height"] as? Double)
        let viewportHeight = try XCTUnwrap(restored["viewport"] as? Double)
        XCTAssertEqual(try y(2, in: restored), -max(height - viewportHeight, 0) * 0.45, accuracy: 1.5)
        XCTAssertEqual(app.staticTexts["continuous-state"].label, oldProgress, "程序恢复不能假装用户已经读到新章")
        drag(app, from: 0.64, to: 0.55)
        let predicate = NSPredicate(format: "label CONTAINS %@", "chapter=2;")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate,
            object: app.staticTexts["continuous-state"])], timeout: 5), .completed)
        XCTAssertEqual(app.statusBars.count, 0)
    }

    func testShortChaptersDoNotWriteProgressOnLayout() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--continuous-scroll-mode", "--continuous-short"]
        app.launch()
        XCTAssertTrue(app.buttons["scroll-inspect"].waitForExistence(timeout: 10))
        let first = try inspect(app)
        XCTAssertEqual((first["frames"] as? [[String: Any]])?.count, 2)
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("chapter=1;position=0;changes=0"))
        app.buttons["scroll-prepend"].tap()
        let inserted = try inspect(app)
        XCTAssertEqual(try y(1, in: inserted), try y(1, in: first), accuracy: 1)
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("changes=0"))
        app.buttons["scroll-append"].tap()
        _ = try inspect(app)
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("changes=0"))
    }

    private func inspect(_ app: XCUIApplication) throws -> [String: Any] {
        app.buttons["scroll-inspect"].tap()
        let data = try XCTUnwrap(app.staticTexts["continuous-metrics"].label.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func frame(_ id: Int, in report: [String: Any]) throws -> [String: Any] {
        let frames = try XCTUnwrap(report["frames"] as? [[String: Any]])
        return try XCTUnwrap(frames.first { ($0["title"] as? String)?.hasPrefix("第\(id)章") == true })
    }
    private func y(_ id: Int, in report: [String: Any]) throws -> Double {
        try XCTUnwrap(frame(id, in: report)["y"] as? Double)
    }
    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
}
