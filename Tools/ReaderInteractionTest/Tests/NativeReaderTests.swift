import XCTest

final class NativeReaderTests: XCTestCase {
    func testNativeCurlCachedChaptersThemeAndRefresh() { checkNative("curl") }
    func testNativeSlideCachedChapters() { checkNative("slide") }

    func testNativeCurlSlowChapterFallback() {
        let app = launch("curl", load: "slow")
        expect(app, chapter: 0, page: 0)
        tap(app, 0.91)
        expect(app, chapter: 0, page: 1)
        inspect(app, mode: "curl", current: "0:1", before: "0:0", after: "none")
        drag(app, direction: 1, cancelled: true)
        expect(app, chapter: 0, page: 1) // 缺少预加载也不能把短拖回弹当作切章。
        drag(app, direction: 1)
        expect(app, chapter: 1, page: 0, edges: 1, slow: 1)
        inspect(app, mode: "curl", current: "1:0", before: "none", after: "1:1")
        drag(app, direction: -1)
        expect(app, chapter: 0, page: 1, edges: 2, slow: 2)
        inspect(app, mode: "curl", current: "0:1", before: "0:0", after: "none")
    }

    private func checkNative(_ mode: String) {
        let app = launch(mode)
        expect(app, chapter: 0, page: 0)
        inspect(app, mode: mode, current: "0:0", before: "none", after: "0:1")
        if mode == "curl" { attach(app, name: "native-curl-light-settled") }

        drag(app, direction: 1)
        expect(app, chapter: 0, page: 1)
        // 必须从生产 dataSource 查到下一章的 ReaderPageHost，不能只看 onEdge 次数。
        inspect(app, mode: mode, current: "0:1", before: "0:0", after: "1:0")
        drag(app, direction: 1, cancelled: true, observe: true)
        expect(app, chapter: 0, page: 1)
        expectDuring(inspect(app, mode: mode, current: "0:1", before: "0:0", after: "1:0"),
                     chapter: 0, page: 1, commits: 0)

        drag(app, direction: 1, observe: true)
        expect(app, chapter: 1, page: 0, commits: 1, last: "1:0")
        expectDuring(inspect(app, mode: mode, current: "1:0", before: "0:1", after: "1:1"),
                     chapter: 0, page: 1, commits: 0)

        var revision = 0
        let dark = mode == "curl"
        if dark {
            app.buttons["toggle-theme"].tap()
            expect(app, chapter: 1, page: 0, commits: 1, last: "1:0", dark: true)
            inspect(app, mode: mode, current: "1:0", before: "0:1", after: "1:1")
            // 同 contentID、相同页数、同 current 更新实际正文；预加载邻章也应拿到新主题/正文。
            app.buttons["refresh-content"].tap()
            revision = 1
            expect(app, chapter: 1, page: 0, commits: 1, last: "1:0", revision: revision, dark: true)
            inspect(app, mode: mode, current: "1:0", before: "0:1", after: "1:1")
            attach(app, name: "native-curl-dark-settled")
            drag(app, direction: -1, cancelled: true, observe: true)
            expect(app, chapter: 1, page: 0, commits: 1, last: "1:0", revision: revision, dark: true)
            expectDuring(inspect(app, mode: mode, current: "1:0", before: "0:1", after: "1:1"),
                         chapter: 1, page: 0, commits: 1)
        }
        drag(app, direction: -1, observe: true)
        expect(app, chapter: 0, page: 1, commits: 2, last: "-1:1", revision: revision, dark: dark)
        expectDuring(inspect(app, mode: mode, current: "0:1", before: "0:0", after: "1:0"),
                     chapter: 1, page: 0, commits: 1)
        if mode == "slide" { attach(app, name: "native-slide-settled") }
    }

    private func launch(_ mode: String, load: String = "cached") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--chapter-mode=\(mode)", "--chapter-load=\(load)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chapter-state"].waitForExistence(timeout: 8))
        return app
    }

    private func expect(_ app: XCUIApplication, chapter: Int, page: Int, edges: Int = 0,
                        commits: Int = 0, last: String = "none", revision: Int = 0, dark: Bool = false, slow: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line) {
        let state = app.staticTexts["chapter-state"]
        let titles = app.staticTexts.matching(identifier: "reader-footer-title")
        let numbers = app.staticTexts.matching(identifier: "reader-footer-page")
        let expected = ["chapter": "\(chapter)", "page": "\(page)", "edges": "\(edges)", "loading": "false",
                        "bars": "0", "locked": "false", "contentID": "\(chapter)", "count": "2",
                        "revision": "\(revision)", "commits": "\(commits)", "cached": "\(commits)",
                        "invalid": "0", "last": last, "theme": dark ? "dark" : "light", "slow": "\(slow)"]
        let title = "第\(chapter + 1)章，第\(page + 1)页" + (revision == 0 ? "" : " · 更新\(revision)")
        let predicate = NSPredicate { _, _ in
            guard state.exists, titles.count == 1, numbers.count == 1 else { return false }
            let actual = self.fields(state.label)
            return expected.allSatisfy { actual[$0.key] == $0.value }
                && titles.element(boundBy: 0).label == title && numbers.element(boundBy: 0).label == "\(page + 1)/2"
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: state)], timeout: 6)
        XCTAssertEqual(result, .completed,
            "state=\(state.exists ? state.label : "missing"); footer=\(titles.count == 1 ? titles.element(boundBy: 0).label : "count=\(titles.count)")", file: file, line: line)
        XCTAssertEqual(app.statusBars.count, 0, "阅读页面不应显示系统状态栏", file: file, line: line)
    }

    @discardableResult
    private func inspect(_ app: XCUIApplication, mode: String, current: String, before: String, after: String,
                         file: StaticString = #filePath, line: UInt = #line) -> [String: String] {
        app.buttons["inspect-native"].tap()
        let actual = fields(app.staticTexts["native-info"].label)
        let expected = ["native": "true", "transition": mode == "curl" ? "curl" : "scroll",
                        "double": mode == "curl" ? "true" : "false", "idle": "true",
                        "current": current, "before": before, "after": after, "chainValid": "true",
                        "bodyCurrent": "true", "alignment": "production", "baseline": "true", "continuation": "true",
                        "containerTheme": "true", "frontTheme": "true", "backsTheme": "true",
                        "backsOpaque": "true", "backsHidden": "true", "backsPaperText": "true",
                        "backsMirrored": "true", "backsInert": "true", "currentOnly": "true", "statusHidden": "true"]
        assertFields(actual, expected, file: file, line: line)
        let backs = Int(actual["backCount"] ?? "") ?? -1
        if mode == "curl" { XCTAssertGreaterThan(backs, 0, "必须查到真实纸背", file: file, line: line) }
        else { XCTAssertEqual(backs, 0, file: file, line: line) }
        return actual
    }

    private func expectDuring(_ actual: [String: String], chapter: Int, page: Int, commits: Int,
                              file: StaticString = #filePath, line: UInt = #line) {
        // 读数发生在系统 recognizer.changed + coordinator 非 idle 时，而非测试补调完成回调。
        assertFields(actual, ["observed": "true", "duringIdle": "false", "duringChapter": "\(chapter)",
                              "duringPage": "\(page)", "duringEdges": "0", "duringCommits": "\(commits)",
                              "duringLoading": "false"], file: file, line: line)
    }

    private func fields(_ label: String) -> [String: String] {
        var result: [String: String] = [:]
        for entry in label.split(separator: ";") {
            let pair = entry.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    private func assertFields(_ actual: [String: String], _ expected: [String: String],
                              file: StaticString, line: UInt) {
        for (key, value) in expected {
            XCTAssertEqual(actual[key], value, "\(key): \(actual)", file: file, line: line)
        }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func point(_ app: XCUIApplication, _ x: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.55))
    }
    private func tap(_ app: XCUIApplication, _ x: CGFloat) { point(app, x).tap() }
    private func drag(_ app: XCUIApplication, direction: Int, cancelled: Bool = false, observe: Bool = false) {
        if observe { app.buttons["arm-native-drag"].tap() }
        let start: CGFloat = direction > 0 ? 0.93 : 0.07
        let end: CGFloat = cancelled ? (direction > 0 ? 0.85 : 0.15) : (direction > 0 ? 0.07 : 0.93)
        // 短拖超过系统 pan slop，但不足以翻页；松手前停顿消除甩动速度，不用私有事件注入。
        point(app, start).press(forDuration: 0.03, thenDragTo: point(app, end),
                               withVelocity: cancelled ? XCUIGestureVelocity(rawValue: 80) : .slow,
                               thenHoldForDuration: cancelled ? 0.4 : 0.15)
    }
}
