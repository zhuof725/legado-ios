import Foundation

enum ChapterNavigationRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let readable = [true, false, false, true, false, true, false]
        func find(_ start: Int, _ direction: Int) -> Int? {
            ChapterNavigation.readableIndex(from: start, direction: direction,
                                             count: readable.count) { readable[$0] }
        }
        check(find(1, 1) == 3, "跨章：向前跳过分卷和空链接")
        check(find(4, -1) == 3, "跨章：向后跳过目录标题")
        check(find(-1, -1) == nil && find(7, 1) == nil, "跨章：书首书尾不夹回本章")
        check(find(6, 1) == nil, "跨章：末尾都是分卷标题时停止")
        check(ChapterNavigation.readableIndex(from: 0, direction: 1, count: 0) { _ in true } == nil,
              "跨章：空目录不访问无效下标")
        var gesture = ScrollChapterAdvance()
        check(!gesture.shouldAdvance(chapterID: "1", enabled: true, atBottom: true),
              "滚动跨章：初始布局在底部不自动跳")
        gesture.begin(chapterID: "1", enabled: true)
        check(!gesture.shouldAdvance(chapterID: "1", enabled: true, atBottom: true),
              "滚动跨章：手指未抬起不切换正文")
        gesture.end(horizontal: 0, vertical: -150, cancelled: false)
        check(!gesture.shouldAdvance(chapterID: "1", enabled: true, atBottom: false),
              "滚动跨章：未到底部仍留在本章")
        check(gesture.shouldAdvance(chapterID: "1", enabled: true, atBottom: true),
              "滚动跨章：抬手后到达底部触发下一章")
        check(!gesture.shouldAdvance(chapterID: "1", enabled: true, atBottom: true),
              "滚动跨章：同次手势惯性只触发一次")
        check(!gesture.shouldAdvance(chapterID: "2", enabled: true, atBottom: true),
              "滚动跨章：旧章惯性不能推进新章")
        for delta in [(0.0, 70.0), (160, -30), (0, -6)] {
            gesture.begin(chapterID: "2", enabled: true)
            gesture.end(horizontal: delta.0, vertical: delta.1, cancelled: false)
            check(!gesture.shouldAdvance(chapterID: "2", enabled: true, atBottom: true),
                  "滚动跨章：反方向横移和轻触不跳章 \(delta)")
        }
        gesture.begin(chapterID: "2", enabled: true)
        gesture.end(horizontal: 0, vertical: -180, cancelled: true)
        check(!gesture.shouldAdvance(chapterID: "2", enabled: true, atBottom: true), "滚动跨章：取消手势不跳章")
        gesture.begin(chapterID: "2", enabled: false)
        gesture.end(horizontal: 0, vertical: -180, cancelled: false)
        check(!gesture.shouldAdvance(chapterID: "2", enabled: true, atBottom: true), "滚动跨章：加载时开始的手势无效")
        gesture.begin(chapterID: "2", enabled: true)
        gesture.end(horizontal: 0, vertical: -180, cancelled: false)
        check(!gesture.shouldAdvance(chapterID: "2", enabled: false, atBottom: true), "滚动跨章：加载中不接收下一章")
        gesture.reset()
        check(!gesture.shouldAdvance(chapterID: "2", enabled: true, atBottom: true), "滚动跨章：恢复位置不触发下一章")
    }
}
