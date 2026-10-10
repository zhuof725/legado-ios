import XCTest

final class CoverTurnTests: XCTestCase {
    func testCoverGeometryCancellationAndChapterAdoption() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--cover-mode"]
        app.launch()
        XCTAssertTrue(app.staticTexts["cover-state"].waitForExistence(timeout: 10))
        expect(app, chapter: 0, page: 0, commits: 0)
        try drag(app, from: 0.86, to: 0.16)
        expect(app, chapter: 0, page: 1, commits: 0)
        try assertCover(app)

        // 章末短拖撤回：仍留在旧章末，不改进度。
        try drag(app, from: 0.86, to: 0.77)
        expect(app, chapter: 0, page: 1, commits: 0)
        try assertCover(app)
        try drag(app, from: 0.86, to: 0.15)
        expect(app, chapter: 1, page: 0, commits: 1)
        try assertCover(app)

        app.buttons["cover-theme"].tap()
        app.buttons["cover-refresh"].tap()
        expect(app, chapter: 1, page: 0, commits: 1, revision: 1)
        try drag(app, from: 0.12, to: 0.21)
        expect(app, chapter: 1, page: 0, commits: 1, revision: 1)
        try assertCover(app)
        try drag(app, from: 0.12, to: 0.88)
        expect(app, chapter: 0, page: 1, commits: 2, revision: 1)
        try assertCover(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.55)).tap()
        expect(app, chapter: 1, page: 0, commits: 3, revision: 1)
        XCTAssertEqual(app.statusBars.count, 0)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "cover-night-settled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func drag(_ app: XCUIApplication, from: CGFloat, to: CGFloat) throws {
        app.buttons["cover-arm"].tap()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: from, dy: 0.55))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: to, dy: 0.55))
        start.press(forDuration: 0.03, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    private func expect(_ app: XCUIApplication, chapter: Int, page: Int, commits: Int, revision: Int = 0,
                        file: StaticString = #filePath, line: UInt = #line) {
        let state = app.staticTexts["cover-state"]
        let expected = "chapter=\(chapter);page=\(page);commits=\(commits);edges=0;revision=\(revision);bars=0"
        let titles = app.staticTexts.matching(identifier: "reader-footer-title")
        let condition = NSPredicate { _, _ in
            state.exists && state.label == expected && titles.count == 1
                && titles.element(boundBy: 0).label == "第\(chapter + 1)章，第\(page + 1)页，版本\(revision)"
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: state)], timeout: 6), .completed,
                       state.exists ? state.label : "missing", file: file, line: line)
    }
    private func assertCover(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        app.buttons["cover-inspect"].tap()
        let raw = app.staticTexts["cover-metrics"].label
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let current = try XCTUnwrap(report["current"] as? [String: Any])
        let during = try XCTUnwrap(report["during"] as? [String: Any])
        XCTAssertEqual(current["idle"] as? Bool, true, raw, file: file, line: line)
        XCTAssertEqual(during["tracking"] as? Bool, true, raw, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(during["underX"] as? Double), 0, accuracy: 0.1, file: file, line: line)
        XCTAssertLessThan(try XCTUnwrap(during["coverX"] as? Double), -1, file: file, line: line)
        XCTAssertGreaterThan(try XCTUnwrap(during["corner"] as? Double), 1, file: file, line: line)
        XCTAssertGreaterThan(try XCTUnwrap(during["progress"] as? Double), 0.02, file: file, line: line)
        XCTAssertLessThanOrEqual(try XCTUnwrap(during["dim"] as? Double), 0.101, file: file, line: line)
    }
}
