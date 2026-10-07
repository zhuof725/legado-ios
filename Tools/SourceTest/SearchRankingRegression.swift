import Foundation

/// 搜索结果合并与排序。纯函数，离线。
enum SearchRankingRegression {
    private static func book(_ name: String, _ author: String = "", origin: String = "o", cover: String? = nil, intro: String? = nil) -> Book {
        var b = Book(bookUrl: "https://\(origin).invalid/\(name)\(author)", name: name, origin: origin)
        b.author = author; b.originName = origin; b.coverUrl = cover; b.intro = intro
        return b
    }

    static func run(_ check: (Bool, String) -> Void) {
        check(SearchRanking.rank(name: "星门", author: "", key: "星门") == 0, "搜索排序：书名完全相同最前")
        check(SearchRanking.rank(name: "星门的囚笼", author: "", key: "星门") == 1, "搜索排序：书名前缀其次")
        check(SearchRanking.rank(name: "穿越星门", author: "", key: "星门") == 2, "搜索排序：书名包含")
        check(SearchRanking.rank(name: "无关", author: "星门作者", key: "星门") == 3, "搜索排序：作者匹配")
        check(SearchRanking.rank(name: "无关", author: "他", key: "星门") == 4, "搜索排序：不相关最后")
        check(SearchRanking.rank(name: " 星 门！", author: "", key: "星门") == 0, "搜索排序：忽略空白与标点")
        check(SearchRanking.rank(name: "Dune", author: "", key: "dune") == 0, "搜索排序：忽略大小写")

        var hits: [SearchHit] = []
        hits = SearchRanking.merge(existing: hits, new: [book("穿越星门", "甲"), book("星门的囚笼", "乙", origin: "a")], key: "星门")
        check(hits.map(\.book.name) == ["星门的囚笼", "穿越星门"], "合并：按相关度排序（前缀先于包含）")
        hits = SearchRanking.merge(existing: hits, new: [book("星门", "丙", origin: "b"), book("星门的囚笼", " 乙", origin: "c", cover: "cv", intro: "in")], key: "星门")
        check(hits.map(\.book.name) == ["星门", "星门的囚笼", "穿越星门"], "合并：后到的完全匹配排到最前")
        let dup = hits.first { $0.book.name == "星门的囚笼" }
        check(dup?.sourceCount == 2, "合并：同书名同作者合并并累计来源数")
        check(dup?.book.coverUrl == "cv" && dup?.book.intro == "in", "合并：补全缺失的封面与简介")
        check(hits.count == 3, "合并：重复条目不增加行数")

        let a = [book("星门A", "x", origin: "1")]
        var order = SearchRanking.merge(existing: [], new: a, key: "星门")
        order = SearchRanking.merge(existing: order, new: [book("星门B", "y", origin: "2")], key: "星门")
        check(order.map(\.book.name) == ["星门A", "星门B"], "合并：同级同来源数按先到先得")
        order = SearchRanking.merge(existing: order, new: [book("星门B", "y", origin: "3")], key: "星门")
        check(order.map(\.book.name) == ["星门B", "星门A"], "合并：同级时来源多的靠前")
        check(SearchRanking.merge(existing: [], new: [book("")], key: "x").isEmpty, "合并：空书名被丢弃")
        check(SearchRanking.merge(existing: [], new: [book("甲", "乙")], key: "").first?.rank == 4, "排序：关键词为空不崩溃")
    }
}
