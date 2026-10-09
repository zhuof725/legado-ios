import Foundation

/// 查找真实章节，不把越界的下一章请求夹回本章，也不打开分卷标题。
enum ChapterNavigation {
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
