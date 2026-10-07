import Foundation

/// 目录节点解析、去重、卷标题、updateTime。离线 HTML，不发请求。
enum TocParseRegression {
    static func run(_ check: (Bool, String) -> Void) throws {
        let html = """
        <ul>
        <li class="v">第一卷</li>
        <li><a href="/c/1">序章</a><i>2024-01-01</i></li>
        <li><a href="/c/2">第一章</a><i>2024-01-02</i></li>
        <li><a href="/c/2">第一章</a><i>2024-01-02</i></li>
        <li><span>无链接</span></li>
        <li><a href="/c/3">第二章</a></li>
        </ul>
        """
        let rule = TocRule(chapterList: "li", chapterName: "a@text||.v@text", chapterUrl: "a@href",
                           isVolume: "class.v.0@text", updateTime: "i@text")
        let base = "https://toc.invalid/book/1"
        let ar = AnalyzeRule(content: html, baseUrl: base)
        let nodes = ar.getElements("li")
        check(nodes.count == 6, "目录：列表节点数")
        let parsed = WebBook.parseChapterNodes(nodes, rule: rule, ar: ar, baseUrl: base)
        check(parsed.contains { $0.url == "https://toc.invalid/c/1" && $0.title == "序章" }, "目录：相对链接补全为绝对地址")
        check(!parsed.contains { $0.title == "无链接" }, "目录：普通章节无链接则跳过")
        check(parsed.first(where: { $0.url == "https://toc.invalid/c/1" })?.updateTime == "2024-01-01", "目录：ruleToc.updateTime 被解析")
        check(parsed.first(where: { $0.url == "https://toc.invalid/c/3" })?.updateTime == nil, "目录：缺少 updateTime 时为空")

        func ch(_ u: String, _ t: String, vol: Bool = false) -> BookChapter {
            BookChapter(url: u, title: t, index: 0, isVolume: vol)
        }
        let dup = [ch("", "卷一", vol: true), ch("a", "A"), ch("b", "B"), ch("a", "A重复"), ch("", "卷二", vol: true), ch("c", "C")]
        let d = WebBook.dedupeChapters(dup)
        check(d.map(\.title) == ["卷一", "A", "B", "卷二", "C"], "目录：按 url 去重保留首次出现，空 URL 卷标题不去重")
    }
}

enum NextUrlRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let base = "https://next.invalid/book/1/2.html"
        check(WebBook.splitNextUrls("", base: base).isEmpty, "下一页地址：空串无结果")
        check(WebBook.splitNextUrls("  \n \n", base: base).isEmpty, "下一页地址：全空白无结果")
        check(WebBook.splitNextUrls("/p/3", base: base) == ["https://next.invalid/p/3"], "下一页地址：相对地址补全")
        let multi = WebBook.splitNextUrls("/p/3\n /p/4 \n/p/3\n\nhttps://other.invalid/x", base: base)
        check(multi == ["https://next.invalid/p/3", "https://next.invalid/p/4", "https://other.invalid/x"],
              "下一页地址：多行去空白、去重、保序")
    }
}

enum CookieDomainRegression {
    static func run(_ check: (Bool, String) -> Void) {
        check(WebViewSupport.cookieDomain(".a.com", matches: "www.a.com"), "Cookie 域：父域 Cookie 适用于子域")
        check(WebViewSupport.cookieDomain("www.a.com", matches: "www.a.com"), "Cookie 域：同主机适用")
        check(!WebViewSupport.cookieDomain("a.com", matches: "nota.com"), "Cookie 域：后缀相同但不是子域，不适用")
        check(!WebViewSupport.cookieDomain("b.com", matches: "www.a.com"), "Cookie 域：无关站点不适用")
        check(!WebViewSupport.cookieDomain("", matches: "a.com"), "Cookie 域：空域不适用")
    }
}
