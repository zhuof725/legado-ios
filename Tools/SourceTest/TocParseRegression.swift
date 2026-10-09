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

        let vipRule = TocRule(chapterList: "li", chapterName: "a@text", chapterUrl: "a@href", isVip: "i@text")
        let vipHTML = "<ul><li><a href='/v/1'>免费</a><i></i></li><li><a href='/v/2'>付费</a><i>true</i></li><li><a href='/v/3'>零</a><i>0</i></li><li><a href='/v/4'>假</a><i>false</i></li><li><a href='/v/5'>是</a><i>1</i></li></ul>"
        let vipAr = AnalyzeRule(content: vipHTML, baseUrl: base)
        let vip = WebBook.parseChapterNodes(vipAr.getElements("li"), rule: vipRule, ar: vipAr, baseUrl: base)
        check(vip.map(\.isVip) == [false, true, false, false, true], "目录：isVip 按 空/false/0 为假、其余为真")
        let novip = WebBook.parseChapterNodes(nodes, rule: rule, ar: ar, baseUrl: base)
        check(novip.allSatisfy { !$0.isVip }, "目录：未配置 isVip 时全部为非付费")
        check(WebBook.isTruthy("true") && WebBook.isTruthy("1") && !WebBook.isTruthy(" ") && !WebBook.isTruthy("null"), "isTruthy 判定")

        // 旧版本落盘的目录缓存（没有 updateTime/isVip）必须仍可读取。
        let oldJSON = "[{\"url\":\"https://old.invalid/1\",\"title\":\"旧章\",\"index\":0,\"isVolume\":false},{\"url\":\"\",\"title\":\"旧卷\",\"index\":1}]"
        let old = try? JSONDecoder().decode([BookChapter].self, from: Data(oldJSON.utf8))
        check(old?.count == 2 && old?[0].isVip == false && old?[0].updateTime == nil && old?[1].isVolume == false, "目录缓存：旧版 JSON（缺 isVip/updateTime）仍可解码")
        let round = try? JSONDecoder().decode(BookChapter.self, from: JSONEncoder().encode(BookChapter(url: "u", title: "t", index: 3, isVolume: true, updateTime: "x", isVip: true)))
        check(round?.isVip == true && round?.updateTime == "x" && round?.isVolume == true && round?.index == 3, "目录缓存：新字段编码解码往返")

        func ch(_ u: String, _ t: String, vol: Bool = false) -> BookChapter {
            BookChapter(url: u, title: t, index: 0, isVolume: vol)
        }
        let dup = [ch("", "卷一", vol: true), ch("a", "A"), ch("b", "B"), ch("a", "A重复"), ch("", "卷二", vol: true), ch("c", "C")]
        let d = WebBook.dedupeChapters(dup)
        check(d.map(\.title) == ["卷一", "A", "B", "卷二", "C"], "目录：按 url 去重保留首次出现，空 URL 卷标题不去重")
        let shared = [ch("a", "卷一", vol: true), ch("a", "第一章"), ch("a", "重复章"), ch("a", "卷二", vol: true)]
        check(WebBook.dedupeChapters(shared).map(\.title) == ["卷一", "第一章", "卷二"],
              "目录：卷标题和章节共用链接时两者均保留")
        let volumeHTML = "<ul><li data-title='卷名' data-volume='卷名'></li><li data-title='章节' data-url='/1' data-volume='0'></li></ul>"
        let volumeRule = TocRule(chapterList: "li", chapterName: "data-title", chapterUrl: "data-url", isVolume: "data-volume")
        let volumes = WebBook.parseChapterNodes(AnalyzeRule(content: volumeHTML, baseUrl: base).getElements("li"),
            rule: volumeRule, ar: AnalyzeRule(content: volumeHTML, baseUrl: base), baseUrl: base)
        check(volumes.contains { $0.title == "卷名" && $0.isVolume }, "目录：书源卷标记为文本时仍保留无链接卷名")
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
