import XCTest

final class ContinuousScrollTests: XCTestCase {
    func testInlineChapterBoundaryAndStablePrependAppendRestore() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--continuous-scroll-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["scroll-boundary"].waitForExistence(timeout: 10))
        let initial = try inspect(app)
        let unsaved = app.staticTexts["continuous-settled"].label
        XCTAssertEqual(unsaved, "settlements=0;savedChapter=-1;savedPosition=-1")
        app.buttons["scroll-boundary"].tap()
        let before = try inspect(app)
        try assertWork(from: initial, to: before, added: 0)
        XCTAssertEqual(app.staticTexts["continuous-settled"].label, unsaved)
        XCTAssertEqual(before["native"] as? Bool, true)
        let start = try frame(1, in: before)
        let progress = app.staticTexts["continuous-state"].label
        app.buttons["scroll-prepend"].tap()
        let inserted = try inspect(app)
        XCTAssertEqual(try y(1, in: inserted), try XCTUnwrap(start["y"] as? Double), accuracy: 1)
        try assertWork(from: before, to: inserted, added: 1)
        XCTAssertEqual(app.staticTexts["continuous-settled"].label, unsaved)
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("changes=0"))
        app.buttons["scroll-append"].tap()
        let appended = try inspect(app)
        XCTAssertEqual(try y(1, in: appended), try y(1, in: inserted), accuracy: 1)
        try assertWork(from: inserted, to: appended, added: 1)
        XCTAssertEqual(app.staticTexts["continuous-settled"].label, unsaved)
        app.buttons["scroll-trim"].tap()
        let trimmed = try inspect(app)
        XCTAssertEqual(try y(1, in: trimmed), try y(1, in: inserted), accuracy: 1)
        try assertWork(from: appended, to: trimmed, added: 0)
        XCTAssertEqual(app.staticTexts["continuous-settled"].label, unsaved)
        XCTAssertTrue(progress.contains("changes=0"))
        XCTAssertTrue(app.staticTexts["continuous-state"].label.contains("changes=0"))

        // 一次真实拖动让章尾与下一章标题同时出现，仍然是同一 UIScrollView。
        drag(app, from: 0.67, to: 0.49)
        waitForSettlements(app, count: 1)
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
        let oldSaved = app.staticTexts["continuous-settled"].label
        app.buttons["scroll-restore"].tap()
        let restored = try inspect(app)
        let chapter2 = try frame(2, in: restored)
        let height = try XCTUnwrap(chapter2["height"] as? Double)
        let viewportHeight = try XCTUnwrap(restored["viewport"] as? Double)
        XCTAssertEqual(try y(2, in: restored), -max(height - viewportHeight, 0) * 0.45, accuracy: 1.5)
        XCTAssertEqual(app.staticTexts["continuous-state"].label, oldProgress, "程序恢复不能假装用户已经读到新章")
        XCTAssertEqual(app.staticTexts["continuous-settled"].label, oldSaved, "程序恢复不能触发保存")

        // 三次短原生拖动都留在第二章；onPosition 每帧更新 @State 后仍不能重装或重测稳定正文。
        XCTAssertGreaterThan(height, viewportHeight * 3, "测试正文必须足够长，避免拖动越章")
        var previous = restored
        var previousChanges = try field("changes", in: oldProgress)
        var alignedGlyphs = 0, alignedQuotes = 0
        let drags: [(CGFloat, CGFloat)] = [(0.64, 0.55), (0.64, 0.50), (0.49, 0.62)]
        for (index, gesture) in drags.enumerated() {
            drag(app, from: gesture.0, to: gesture.1)
            waitForSettlements(app, count: index + 2)
            let after = try inspect(app)
            let progress = app.staticTexts["continuous-state"].label
            let saved = app.staticTexts["continuous-settled"].label
            XCTAssertEqual(try field("chapter", in: progress), 2, progress)
            XCTAssertGreaterThan(try field("changes", in: progress), previousChanges, progress)
            XCTAssertEqual(try field("savedChapter", in: saved), 2, saved)
            XCTAssertEqual(try field("savedPosition", in: saved), try field("position", in: progress))
            let localY = -(try y(2, in: after))
            XCTAssertGreaterThan(localY, 0)
            XCTAssertLessThan(localY, height - viewportHeight, "拖动后仍应位于同章内部")
            let expected = Int(min(max(localY / max(height - viewportHeight, 1), 0), 1) * 1000)
            XCTAssertEqual(Double(try field("savedPosition", in: saved)), Double(expected), accuracy: 1,
                           "保存值必须对应原生 UIScrollView 的最终位置")
            let delta = (try number("offset", in: after)) - (try number("offset", in: previous))
            if gesture.0 > gesture.1 { XCTAssertGreaterThan(delta, 5) }
            else { XCTAssertLessThan(delta, -5) }
            for id in [1, 2, 3] {
                XCTAssertEqual(try number("height", in: frame(id, in: after)),
                               try number("height", in: frame(id, in: restored)), accuracy: 1)
                XCTAssertEqual(try y(id, in: after), try y(id, in: previous) - delta, accuracy: 1,
                               "滚动只能平移已缓存章节，不能引起布局跳动")
            }
            try assertWork(from: restored, to: after, added: 0)
            let alignment = try XCTUnwrap(after["alignment"] as? [String: Any])
            XCTAssertLessThanOrEqual(try number("gridError", in: alignment), 0.25,
                                     "CJK 对话与引号应保持纵向字列：\(alignment)")
            alignedGlyphs += Int(try number("glyphs", in: alignment))
            alignedQuotes += Int(try number("quotes", in: alignment))
            previous = after
            previousChanges = try field("changes", in: progress)
        }
        XCTAssertGreaterThan(alignedGlyphs, 100, "必须检查实际显示的 CJK 字形")
        XCTAssertGreaterThan(alignedQuotes, 0, "必须覆盖实际排版的对话引号")
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

    private func number(_ key: String, in report: [String: Any]) throws -> Double {
        try XCTUnwrap(report[key] as? NSNumber, "Missing \(key): \(report)").doubleValue
    }
    private func field(_ key: String, in label: String) throws -> Int {
        let values = Dictionary(uniqueKeysWithValues: label.split(separator: ";").compactMap { item -> (String, String)? in
            let pair = item.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        let digits = try XCTUnwrap(values[key]).filter { $0.isNumber || $0 == "-" }
        return try XCTUnwrap(Int(digits))
    }
    private func waitForSettlements(_ app: XCUIApplication, count: Int) {
        let status = app.staticTexts["continuous-settled"]
        let condition = NSPredicate { _, _ in
            status.exists && (try? self.field("settlements", in: status.label)) == count
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: status)], timeout: 5), .completed)
    }
    private func assertWork(from before: [String: Any], to after: [String: Any], added: Int,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let measures = try number("measurementCount", in: after) - number("measurementCount", in: before)
        let installs = try number("contentInstallCount", in: after) - number("contentInstallCount", in: before)
        XCTAssertGreaterThanOrEqual(measures, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(measures, Double(added), "稳定章节不得重测", file: file, line: line)
        XCTAssertEqual(installs, Double(added), "稳定章节不得重新安装", file: file, line: line)
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
