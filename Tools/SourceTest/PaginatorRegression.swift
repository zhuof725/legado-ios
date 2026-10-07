import Foundation

enum PaginatorRegression {
    private static func para(_ n: Int, count: Int = 0) -> ContentBlock {
        .paragraph(text: String(repeating: "字", count: n), commentCount: count, commentURL: count > 0 ? "u" : nil)
    }
    private static func total(_ pages: [BookPage]) -> Int {
        pages.reduce(0) { acc, p in acc + p.blocks.reduce(0) { a, b in if case .paragraph(let t, _, _) = b { return a + t.count }; return a } }
    }

    static func run(_ check: (Bool, String) -> Void) {
        let layout = PageLayout(charsPerLine: 10, linesPerPage: 5)
        check(Paginator.paginate([], layout: layout).isEmpty, "分页：空内容没有页")
        let one = Paginator.paginate([para(8)], layout: layout)
        check(one.count == 1 && total(one) == 8, "分页：短段落一页放得下")

        let blocks = (0..<30).map { _ in para(25) }
        let pages = Paginator.paginate(blocks, layout: layout)
        check(pages.count > 1, "分页：长内容分成多页")
        check(total(pages) == 30 * 25, "分页：切页不丢字也不重复")
        check(pages.map(\.startOffset) == pages.map(\.startOffset).sorted() && pages.first?.startOffset == 0, "分页：页起点偏移递增且从 0 开始")

        // 一个超长段落在行边界拆成多页，评论气泡只挂在最后一块
        let big = Paginator.paginate([para(200, count: 7)], layout: layout)
        check(big.count > 1 && total(big) == 200, "分页：超长段落跨页拆分且字数守恒")
        let counts = big.flatMap { $0.blocks }.compactMap { b -> Int? in if case .paragraph(_, let c, _) = b { return c }; return nil }
        check(counts.filter { $0 > 0 } == [7] && counts.last == 7, "分页：段评气泡只出现在段落最后一块")

        // 图片/卡片整块放入，不被拆开；放不下就换页
        let card = ContentBlock.hotComment(label: "热评", text: "x", clickURL: nil)
        let withCard = Paginator.paginate([para(40), card, para(10)], layout: layout)
        check(withCard.flatMap { $0.blocks }.contains(card), "分页：卡片块保留")

        // 位置恢复
        check(Paginator.pageIndex(containing: 0, in: pages) == 0, "分页：偏移 0 在第一页")
        let mid = pages[pages.count / 2].startOffset
        check(Paginator.pageIndex(containing: mid, in: pages) == pages.count / 2, "分页：偏移落在页起点时回到该页")
        check(Paginator.pageIndex(containing: mid + 1, in: pages) == pages.count / 2, "分页：偏移在页中间时回到该页")
        check(Paginator.pageIndex(containing: 999_999, in: pages) == pages.count - 1, "分页：偏移越界落在最后一页")
        check(Paginator.pageIndex(containing: 5, in: []) == 0, "分页：没有页时返回 0")

        // 版面估算
        let l = Paginator.layout(width: 390, height: 800, fontSize: 19, lineSpacing: 8)
        check(l.charsPerLine > 10 && l.linesPerPage > 10, "分页：版面估算有合理的行宽和行数")
        let small = Paginator.layout(width: 390, height: 800, fontSize: 14, lineSpacing: 8)
        check(small.charsPerLine > l.charsPerLine && small.linesPerPage > l.linesPerPage, "分页：字号变小每页容纳更多")
        check(Paginator.blocks(fromPlain: "甲\n\n 乙 \n").count == 2, "分页：纯文本按行成段并去空行")
    }
}
