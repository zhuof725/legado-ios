import XCTest

final class PageRefreshTests: XCTestCase {
    func testSlideRefreshesSameContentIDAndCachedChapter() { checkRefresh("slide") }
    func testCurlRefreshesSameContentIDAndCachedChapter() { checkRefresh("curl") }

    private func checkRefresh(_ mode: String) {
        let reader = ReaderChecks(self, mode: mode, load: "cached")
        let initial = reader.expect(chapter: 0, page: 0, edges: 0)
        reader.app.buttons["refresh-content"].tap()
        reader.expect(chapter: 0, page: 0, edges: 0, revision: 1, faceID: initial.faceID)
        reader.app.buttons["toggle-theme"].tap()
        reader.expect(chapter: 0, page: 0, edges: 0, revision: 1, night: true, faceID: initial.faceID)
        reader.tap(0.91)
        let last = reader.expect(chapter: 0, page: 1, edges: 0, revision: 1, night: true)
        // 相邻页已被预取，再刷新不能继续显示旧缓存内容。
        reader.app.buttons["refresh-content"].tap()
        reader.expect(chapter: 0, page: 1, edges: 0, revision: 2, night: true, faceID: last.faceID)
        reader.tap(0.10)
        reader.expect(chapter: 0, page: 0, edges: 0, revision: 2, night: true, faceID: initial.faceID)
        reader.tap(0.91)
        reader.expect(chapter: 0, page: 1, edges: 0, revision: 2, night: true)
        reader.tap(0.91)
        reader.expect(chapter: 1, page: 0, edges: 1, revision: 2, night: true)
        reader.tap(0.10)
        reader.expect(chapter: 0, page: 1, edges: 2, revision: 2, night: true)
    }
}
