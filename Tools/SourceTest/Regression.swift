import Foundation

/// 固定样例验证解析器，不借助网络成功率，也不会访问登录或验证码。
enum RuleRegression {
    static func run() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { print("FAIL: \(name)"); exit(1) }
            checks += 1; print("PASS: \(name)")
        }
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tools/SourceTest/Fixtures")
        func source(_ file: String) throws -> BookSource {
            try JSONDecoder().decode(BookSource.self, from: Data(contentsOf: fixtures.appendingPathComponent(file)))
        }
        let root: [[String: Any]] = [["name": "甲", "url": "/book/1/a.html"], ["name": "乙", "url": "/book/1/b.html"]]
        check(JsonPath.query(root, "$.[*]").count == 2, "根数组 $.[*]")
        check(JsonPath.query(["chapters": root], "$.chapters.[*]").count == 2, "字段数组 chapters.[*]")
        check(JsonPath.query(root, "$[*]").count == 2, "原有 $[*] 不退化")
        let star = try source("star-source.json")
        let starHTML = """
        <html><body><nav><a href="/book/1/not-chapter.html">首页</a></nav>
        <div class="bookshelf-list"><a href="/book/9197/abc.html">第一章</a><a href="/book/9197/def.html">第二章</a><a href="/">首页</a></div></body></html>
        """
        let sa = AnalyzeRule(content: starHTML, baseUrl: "https://m.xiifan.com/novel/9201.html", context: RuleContext(source: star))
        let starItems = sa.getElements(star.ruleToc?.chapterList)
        check(starItems.count == 2, "星星原始 JS + $.[*] 返回2章")
        if let item = starItems.first {
            check(sa.getString(star.ruleToc?.chapterName, from: item) == "第一章", "星星章节标题")
            check(sa.getString(star.ruleToc?.chapterUrl, from: item) == "/book/9197/abc.html", "星星章节地址")
        }
        let dj = try source("dj-source.json")
        let context = RuleContext(source: dj)
        let searchJSON = """
        {"code":0,"body":{"books":[{"bookId":12385810,"bookName":"测试书籍","url":"/book/12385810","author":"测试作者","desc":"测试简介"}]}}
        """
        let search = AnalyzeRule(content: searchJSON, baseUrl: "https://wechat.idejian.com/api/wechat/search/do", jsLib: dj.jsLib, context: context)
        let searchItems = search.getElements(dj.ruleSearch?.bookList)
        check(searchItems.count == 1, "得间 body.books 简写字段")
        if let item = searchItems.first {
            let bookURL = search.getString(dj.ruleSearch?.bookUrl, from: item)
            check(bookURL == "https://wechat.idejian.com/api/wechat/book/12385810", "得间书籍 URL 使用 jsLib host，不是站点首页")
        }
        let detailsJSON = """
        {"code":0,"body":{"bookInfo":{"bookId":12385810,"bookName":"测试书籍","author":"测试作者","desc":"这是测试简介。","multiCategory":[{"name":"测试分类"}],"tag":"测试标签","bookRating":9.2,"popularity":[100],"like":[20]}}}
        """
        let detail = AnalyzeRule(content: detailsJSON, baseUrl: "https://wechat.idejian.com/api/wechat/book/12385810", jsLib: dj.jsLib, context: context)
        let object = detail.getElements(dj.ruleBookInfo?.`init`).first
        check(object is [String: Any], "得间 body.bookInfo init 保留对象")
        let intro = detail.getString(dj.ruleBookInfo?.intro, from: object)
        check(intro.contains("这是测试简介"), "得间原始混合简介规则取到 desc")
        check(intro.contains("测试分类") && intro.contains("测试标签"), "得间简介嵌套模板与 && 合并")
        check(!intro.contains("{{"), "得间简介无残留模板")
        let toc = detail.getString(dj.ruleBookInfo?.tocUrl, from: object)
        check(toc == "https://wechat.idejian.com/api/wechat/allcatalog/12385810?bookId=12385810&page=1", "得间目录 API 地址")
        let catalog = AnalyzeRule(content: "{\"body\":{\"chapterList\":[{\"name\":\"第一章\",\"url\":\"/chapter/12385810/1.html\"}]}}", baseUrl: toc, jsLib: dj.jsLib, context: context)
        let catalogItems = catalog.getElements(dj.ruleToc?.chapterList)
        check(catalogItems.count == 1, "得间目录列表匹配")
        if let item = catalogItems.first {
            let chapterURL = catalog.getString(dj.ruleToc?.chapterUrl, from: item)
            check(chapterURL == "https://wechat.idejian.com/api/wechat/chapter/12385810/1", "得间章节 API 地址保留 jsLib host")
        }
        let xy = try source("xy-source.json")
        let xyHTML = "<div class=\"bx-random item\"><dl><dt class=\"bx-random\"><a href=\"/txt/abc/\">测试书籍</a></dt></dl><img data-original=\"/cover.jpg\"></div>"
        let xyBooks = WebBook.parseBookList(source: xy, body: xyHTML, baseUrl: "https://min-yuan.com/search/", rule: xy.ruleSearch!)
        check(xyBooks.count == 1 && xyBooks[0].name == "测试书籍", "小原混淆 class 不影响 .item + dt a@text")
        let request = AnalyzeUrl(rawUrl: xy.searchUrl!, key: "测试书籍", baseUrl: xy.bookSourceUrl)
        check(request.method == "POST" && request.body == "searchkey=测试书籍", "小原 POST options 与关键词替换")
        print("REGRESSION PASS: \(checks) 项固定断言；不声称真机网络/WebView 已验证。")
    }
}
