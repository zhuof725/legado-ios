import Foundation

/// 阅读位置：章内位置的钳制、换章清零、持久化。AppStore 在 App 目标里，这里只测不依赖界面的比例换算。
enum ReadingPositionRegression {
    /// 与阅读器里的换算一致：偏移/可滚动长度 -> 千分比 -> 取最近的 0...100 锚点。
    static func permille(offset: Double, content: Double, viewport: Double) -> Int? {
        let scrollable = content - viewport
        guard scrollable > 40 else { return nil }
        return Int((min(max(offset, 0), scrollable) / scrollable) * 1000)
    }
    static func slot(_ permille: Int) -> Int { min(max(Int((Double(permille) / 10).rounded()), 0), 100) }

    static func run(_ check: (Bool, String) -> Void) {
        check(permille(offset: 0, content: 3000, viewport: 800) == 0, "阅读位置：顶部为 0")
        check(permille(offset: 2200, content: 3000, viewport: 800) == 1000, "阅读位置：底部为 1000")
        check(permille(offset: 1100, content: 3000, viewport: 800) == 500, "阅读位置：中间为 500")
        check(permille(offset: -50, content: 3000, viewport: 800) == 0 && permille(offset: 9999, content: 3000, viewport: 800) == 1000, "阅读位置：越界被钳制")
        check(permille(offset: 10, content: 820, viewport: 800) == nil, "阅读位置：内容不足一屏不记录")
        check(slot(0) == 0 && slot(1000) == 100 && slot(504) == 50 && slot(505) == 51, "阅读位置：千分比换算到锚点")
        check(slot(-5) == 0 && slot(1500) == 100, "阅读位置：锚点越界被钳制")
        // 改字号后总长变化：同样的比例换算到新的偏移，位置大致不变
        let before = permille(offset: 1100, content: 3000, viewport: 800)!
        let newOffset = Double(before) / 1000 * (4000 - 800)
        check(abs(newOffset - 1600) < 1, "阅读位置：改字号后按比例落到新偏移")
    }
}
