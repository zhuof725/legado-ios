import Foundation

/// 阅读保留分卷；仅网络抓取跳过无需下载的卷标题。越界请求不会夹回本章。
enum ChapterNavigation {
    static func displayIndex(from start: Int, direction: Int, chapters: [BookChapter]) -> Int? {
        readableIndex(from: start, direction: direction, count: chapters.count) {
            chapters[$0].isVolume || !chapters[$0].url.isEmpty
        }
    }

    static func contentIndex(from start: Int, direction: Int, chapters: [BookChapter]) -> Int? {
        readableIndex(from: start, direction: direction, count: chapters.count) {
            !chapters[$0].isVolume && !chapters[$0].url.isEmpty
        }
    }

    /// 有界的预读窗口：卷标题不计入正文数量，也不从原目录数组删除。
    static func prefetchIndices(after index: Int, chapters: [BookChapter], limit: Int = 3) -> [Int] {
        guard limit > 0, index >= -1, index < chapters.count else { return [] }
        var result: [Int] = []
        var next = index + 1
        while result.count < limit,
              let found = contentIndex(from: next, direction: 1, chapters: chapters) {
            result.append(found)
            next = found + 1
        }
        return result
    }

    static func readableIndex(from start: Int, direction: Int, count: Int,
                              isReadable: (Int) -> Bool) -> Int? {
        guard direction != 0, start >= 0, start < count else { return nil }
        let step = direction > 0 ? 1 : -1
        var candidate = start
        while candidate >= 0 && candidate < count {
            if isReadable(candidate) { return candidate }
            candidate += step
        }
        return nil
    }
}

/// 只有真实向上手势结束后才能触发一次下一章。布局、恢复位置、惯性残留都不能独立切章。
struct ScrollChapterAdvance {
    private var origin: String?
    private var upward = false
    private var released = false
    private var consumed = false

    mutating func begin(chapterID: String, enabled: Bool) {
        origin = enabled ? chapterID : nil
        upward = false
        released = false
        consumed = false
    }

    mutating func end(horizontal: Double, vertical: Double, cancelled: Bool) {
        released = !cancelled
        upward = !cancelled && vertical < -16 && abs(vertical) > abs(horizontal) * 1.2
    }

    mutating func shouldAdvance(chapterID: String, enabled: Bool, atBottom: Bool) -> Bool {
        guard enabled, origin == chapterID, released, upward, !consumed, atBottom else { return false }
        consumed = true
        return true
    }

    mutating func reset() { self = ScrollChapterAdvance() }
}
