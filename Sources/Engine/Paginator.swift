import Foundation

/// 翻页模式的分页：把正文块切成若干页。
/// 不依赖 UIKit：用「每行可容纳的字数」和「每页可容纳的行数」估算，段落过长时在行边界拆开。
/// 估算与真实排版会有出入，所以每页留出安全余量，宁可少放一行也不让文字被截断。
struct PageLayout: Equatable {
    var charsPerLine: Int
    var linesPerPage: Int
    /// 段与段之间折算成的行数。
    var paragraphGapLines: Double = 0.25
    /// 图片/卡片块折算成的行数。
    var cardLines: Double = 2.5
}

struct BookPage: Equatable {
    var blocks: [ContentBlock]
    /// 这一页第一个字在整章里的字符偏移（用于改字号后回到同一位置）。
    var startOffset: Int
    /// 这些块是长段落的续段，渲染时不再添加段首缩进。
    /// 下标对应 blocks；普通段落和 Engine 分页器默认都是空集合。
    var continuationIndices: Set<Int> = []
    /// UIKit 分页器测得的块高度，单位为点；下标对应 blocks。
    /// Engine 分页器不填此字段，保留它不会让 portable paginator 依赖 UIKit。
    var blockHeights: [Double] = []
    /// 非章末纯正文页的垂直匀排余量；行间和段间各增加此值。
    /// nil 保留自然排版（滚动、章末、图片/卡片页及稀疏页）。
    var justifiedGap: Double? = nil
}

enum Paginator {
    static func paginate(_ blocks: [ContentBlock], layout: PageLayout) -> [BookPage] {
        let perLine = max(layout.charsPerLine, 4)
        let maxLines = max(Double(layout.linesPerPage), 3)
        var pages: [BookPage] = []
        var cur: [ContentBlock] = []
        var used = 0.0
        var offset = 0
        var pageStart = 0

        func flush() {
            if !cur.isEmpty { pages.append(BookPage(blocks: cur, startOffset: pageStart)) }
            cur = []; used = 0; pageStart = offset
        }

        for block in blocks {
            switch block {
            case .paragraph(let text, let count, let url):
                // 段首缩进两个全角字符，算进第一行。
                let chars = Array(text)
                var i = 0
                var first = true
                while i < chars.count || (chars.isEmpty && first) {
                    let room = max(maxLines - used - (cur.isEmpty ? 0 : layout.paragraphGapLines), 0)
                    var lines = Int(room.rounded(.down))
                    if lines < 1 {
                        flush()
                        lines = Int(maxLines)
                    }
                    let capacity = lines * perLine - (first ? 2 : 0)
                    let take = min(max(capacity, 1), chars.count - i)
                    let piece = String(chars[i..<(i + take)])
                    let isLast = (i + take) >= chars.count
                    let neededLines = Double(Int((Double(take + (first ? 2 : 0)) / Double(perLine)).rounded(.up)))
                    cur.append(.paragraph(text: piece,
                                          commentCount: isLast ? count : 0,
                                          commentURL: isLast ? url : nil))
                    used += neededLines + (cur.count > 1 ? layout.paragraphGapLines : 0)
                    offset += take
                    i += take
                    first = false
                    if chars.isEmpty { break }
                    if !isLast { flush() }
                }
            default:
                if used + layout.cardLines > maxLines { flush() }
                cur.append(block)
                used += layout.cardLines
            }
        }
        flush()
        return pages
    }

    /// 字符偏移所在的页号（改字号、重新分页后恢复阅读位置）。
    static func pageIndex(containing offset: Int, in pages: [BookPage]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var result = 0
        for (i, p) in pages.enumerated() where p.startOffset <= offset { result = i }
        return result
    }

    /// 由屏幕和字号估算版面（单位：点）。
    static func layout(width: Double, height: Double, fontSize: Double, lineSpacing: Double, padding: Double = 20) -> PageLayout {
        let textWidth = max(width - padding * 2, 80)
        let lineHeight = fontSize * 1.25 + lineSpacing
        return PageLayout(charsPerLine: Int(textWidth / fontSize),
                          linesPerPage: Int(max(height - 48, 120) / lineHeight))
    }

    /// 纯文本（没有评论标记的缓存）按空行成段，进入分页。
    static func blocks(fromPlain text: String) -> [ContentBlock] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}"))) }
            .filter { !$0.isEmpty }
            .map { .paragraph(text: $0, commentCount: 0, commentURL: nil) }
    }
}
