import XCTest

/// 不用 firstMatch/可见性过滤丢掉旧页：暴露多个 footer 本身就是失败。
struct ReaderObservation {
    struct Footer {
        let text: String
        let frame: CGRect
    }
    let state: String
    let metrics: String
    let titles: [Footer]
    let numbers: [Footer]
    let screen: CGRect
    let visibleText: String

    init(_ app: XCUIApplication) {
        screen = app.frame
        let running = app.state == .runningForeground
        func label(_ id: String) -> String {
            guard running, app.staticTexts[id].exists else { return "missing" }
            return app.staticTexts[id].label
        }
        func footers(_ id: String) -> [Footer] {
            guard running else { return [] }
            return app.staticTexts.matching(identifier: id).allElementsBoundByIndex.map {
                Footer(text: $0.label, frame: $0.frame)
            }
        }
        state = label("chapter-state")
        metrics = label("animation-metrics")
        titles = footers("reader-footer-title")
        numbers = footers("reader-footer-page")
        let texts = running ? app.staticTexts.allElementsBoundByIndex + app.textViews.allElementsBoundByIndex : []
        visibleText = texts.filter {
            $0.identifier != "animation-metrics" && !$0.frame.isEmpty && $0.frame.intersects(app.frame)
        }.prefix(40).map {
            "\($0.identifier): \($0.label) \(($0.value as? String) ?? "") @\($0.frame)"
        }.joined(separator: "\n")
    }
    static func fields(_ value: String) -> [String: String] {
        var fields: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        return fields
    }
    var values: [String: String] { Self.fields(metrics) }
    var controllerID: String { values["id"] ?? "missing" }
    var faceID: String { values["face"] ?? "missing" }
    var footerY: CGFloat { titles.first?.frame.midY ?? -1 }
    var description: String {
        "state: \(state)\nmetrics: \(metrics)\nfooter titles: \(titles)\nfooter pages: \(numbers)\n可见文本:\n\(visibleText)"
    }
    func footerMatches(title: String, number: String) -> Bool {
        guard titles.count == 1, numbers.count == 1 else { return false }
        let t = titles[0], n = numbers[0]
        // footer 禁止 hit testing；用屏内有效矩形，不把 isHittable 当可见性。
        return t.text == title && n.text == number && !t.frame.isEmpty && !n.frame.isEmpty
            && screen.contains(t.frame) && screen.contains(n.frame) && abs(t.frame.midY - n.frame.midY) <= 2
    }
    func sameLayout(as old: ReaderObservation) -> Bool {
        guard titles.count == 1, numbers.count == 1, old.titles.count == 1, old.numbers.count == 1,
              controllerID == old.controllerID, faceID == old.faceID else { return false }
        return sameFooter(titles[0], old.titles[0]) && sameFooter(numbers[0], old.numbers[0])
    }
    private func sameFooter(_ a: Footer, _ b: Footer) -> Bool {
        guard a.text == b.text else { return false }
        guard abs(a.frame.minX - b.frame.minX) <= CGFloat(0.5) else { return false }
        guard abs(a.frame.minY - b.frame.minY) <= CGFloat(0.5) else { return false }
        guard abs(a.frame.width - b.frame.width) <= CGFloat(0.5) else { return false }
        return abs(a.frame.height - b.frame.height) <= CGFloat(0.5)
    }
}

final class ReaderChecks {
    let app = XCUIApplication()
    private let test: XCTestCase
    private let style: String
    private let load: String
    private let initialNight: Bool
    private var controllerID: String?

    init(_ test: XCTestCase, mode: String, load: String) {
        self.test = test
        self.style = mode.hasPrefix("curl") ? "curl" : mode
        self.load = load
        self.initialNight = mode == "curl-night"
        test.continueAfterFailure = false
        app.launchArguments = ["--chapter-mode=\(mode)", "--chapter-load=\(load)"]
        app.launch()
        require(app.staticTexts["chapter-state"].waitForExistence(timeout: 10),
                "launch 未出现 chapter-state；先检查启动崩溃/异常日志，不能据此判定 locked 死锁")
    }

    @discardableResult
    func expect(chapter: Int, page: Int, edges: Int, revision: Int = 0, night: Bool? = nil,
                faceID: String? = nil, extra: [String: String] = [:],
                file: StaticString = #filePath, line: UInt = #line) -> ReaderObservation {
        let dark = night ?? initialNight
        let expectedState = ["chapter": "\(chapter)", "page": "\(page)", "edges": "\(edges)",
                             "loading": "false", "locked": "false", "contentID": "\(chapter)", "count": "2",
                             "revision": "\(revision)", "night": "\(dark)", "load": load,
                             "slow": "\(load == "slow" ? edges : 0)", "cached": "\(load == "cached" ? edges : 0)"]
        var expectedMetrics = ["requests": "\(edges)", "ends": "\(edges)", "idle": "true",
                               "front": "\(page)", "fronts": "1", "recording": "false",
                               "style": edges == 0 ? "none" : style]
        if let controllerID { expectedMetrics["id"] = controllerID }
        if let faceID { expectedMetrics["face"] = faceID }
        if style != "fade" { expectedMetrics["paper"] = dark ? "28" : "255" }
        if style == "curl" { expectedMetrics["double"] = "true" }
        expectedMetrics.merge(extra) { _, new in new }
        let title = "第\(chapter + 1)章，第\(page + 1)页" + (revision == 0 ? "" : " · 更新\(revision)")
        let body = "第\(chapter + 1)章，第\(page + 1)页。正文版本\(revision)。"
        var last: ReaderObservation?
        var stableSince: Date?
        var actual = ReaderObservation(app)
        let predicate = NSPredicate { _, _ in
            actual = ReaderObservation(self.app)
            let state = ReaderObservation.fields(actual.state), metrics = actual.values
            let valid = expectedState.allSatisfy { state[$0.key] == $0.value }
                && expectedMetrics.allSatisfy { metrics[$0.key] == $0.value }
                && Int(actual.controllerID) != nil && Int(actual.faceID) != nil
                && metrics["body"]?.hasPrefix(body) == true
                && actual.footerMatches(title: title, number: "\(page + 1)/2")
            guard valid else { last = nil; stableSince = nil; return false }
            if let old = last, actual.sameLayout(as: old), let start = stableSince {
                return Date().timeIntervalSince(start) >= 0.3
            }
            last = actual
            stableSince = Date()
            return false
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app)], timeout: 8)
        require(result == .completed,
                "未在 8s 内同时满足父状态、metrics、唯一可见页脚及稳定 layout。期望 state=\(expectedState), metrics=\(expectedMetrics), footer=\(title) \(page + 1)/2\n最后采样:\n\(actual.description)",
                file: file, line: line)
        controllerID = actual.controllerID
        return actual
    }

    func require(_ condition: Bool, _ message: String,
                 file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        let details = XCTAttachment(string: message)
        details.name = "reader-state-and-visible-page"
        details.lifetime = .keepAlways
        test.add(details)
        if app.state == .runningForeground {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "reader-failure-visible-page"
            screenshot.lifetime = .keepAlways
            test.add(screenshot)
        }
        XCTFail(message, file: file, line: line)
    }

    func tap(_ x: CGFloat, _ y: CGFloat = 0.55) {
        point(x, y).tap()
    }
    func drag(from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
        point(from.0, from.1).press(forDuration: 0.03, thenDragTo: point(to.0, to.1))
    }
    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
}
