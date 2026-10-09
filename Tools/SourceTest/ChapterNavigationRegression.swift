import Foundation

enum ChapterNavigationRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let readable = [true, false, false, true, false, true, false]
        func find(_ start: Int, _ direction: Int) -> Int? {
            ChapterNavigation.readableIndex(from: start, direction: direction,
                                             count: readable.count) { readable[$0] }
        }
        check(find(1, 1) == 3, "目录索引：按调用者提供的可用项向前查找")
        check(find(4, -1) == 3, "目录索引：按调用者提供的可用项向后查找")
        check(find(-1, -1) == nil && find(7, 1) == nil, "跨章：书首书尾不夹回本章")
        check(find(6, 1) == nil, "目录索引：没有满足条件的后续项时停止")
        check(ChapterNavigation.readableIndex(from: 0, direction: 1, count: 0) { _ in true } == nil,
              "跨章：空目录不访问无效下标")
        let chapters = [
            BookChapter(url: "0", title: "前章", index: 0),
            BookChapter(url: "", title: "卷二", index: 1, isVolume: true),
            BookChapter(url: "volume-link", title: "卷二 下", index: 2, isVolume: true),
            BookChapter(url: "3", title: "章三", index: 3),
            BookChapter(url: "", title: "无效普通章", index: 4),
            BookChapter(url: "5", title: "章五", index: 5),
            BookChapter(url: "6", title: "章六", index: 6),
            BookChapter(url: "7", title: "章七", index: 7)
        ]
        check(ChapterNavigation.displayIndex(from: 1, direction: 1, chapters: chapters) == 1,
              "分卷：前章结束后保留空链接卷名")
        check(ChapterNavigation.displayIndex(from: 2, direction: 1, chapters: chapters) == 2,
              "分卷：连续卷标题按原顺序显示")
        check(ChapterNavigation.displayIndex(from: 2, direction: -1, chapters: chapters) == 2,
              "分卷：反向翻页也不跳过卷名")
        check(ChapterNavigation.displayIndex(from: 4, direction: 1, chapters: chapters) == 5,
              "分卷：只略过无链接的非卷章节")
        check(ChapterNavigation.contentIndex(from: 1, direction: 1, chapters: chapters) == 3,
              "预读：网络只抓正文而不请求卷链接")
        check(ChapterNavigation.prefetchIndices(after: 0, chapters: chapters) == [3, 5, 6],
              "预读：穿过卷标题预取三章，不把卷计为正文")
        check(ChapterNavigation.prefetchIndices(after: 6, chapters: chapters) == [7],
              "预读：接近书尾只抓存在的后续章")
        check(ChapterNavigation.prefetchIndices(after: 7, chapters: chapters).isEmpty,
              "预读：书尾不循环下载")
        check(chapters[1].title == "卷二" && chapters[2].title == "卷二 下" && chapters.count == 8,
              "分卷：构建预读列表不会删除原目录标题")
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
