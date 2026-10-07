import Foundation

/// 固定样例验证解析器，不借助网络成功率，也不会访问登录或验证码。
enum RuleRegression {
    static func run() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { print("FAIL: \(name)"); exit(1) }
            checks += 1; print("PASS: \(name)")
        }
        let variableContext = RuleContext()
        check(JSEngine.shared.evalString("java.put('bid','123'); java.get('bid')", context: variableContext) == "123", "java.put/get 单参数变量读写")
        check(JSEngine.shared.evalString("java.get('bid')", context: variableContext) == "123", "同一上下文跨 JS 求值保留变量")
        check(JSEngine.shared.evalString("java.get('missing')", context: variableContext) == "", "未定义变量返回空字符串")
        check(JSEngine.shared.evalString("java.put('https://example.invalid/key','stored'); java.get('https://example.invalid/key')", context: variableContext) == "stored", "URL 形状的单参数 get 仍然读取变量")
        check(JSEngine.shared.evalString("java.put('local','value'); java.get('local')") == "value", "无上下文时单次求值内变量可用")
        check(JSEngine.shared.evalString("java.get('bid')", context: RuleContext()) == "", "独立无书源上下文不串变量")
        check(JSEngine.shared.evalString("libValue", result: "payload", baseUrl: "https://example.invalid/", vars: ["key": "测试", "page": 2], jsLib: "var libValue = [result,baseUrl,key,page].join('|');") == "payload|https://example.invalid/|测试|2", "jsLib 初始化可读取请求绑定")
        check(AnalyzeUrl.substitute("{{'searchKey/searchPage'}}", key: "测试", page: 3) == "searchKey/searchPage", "URL 模板不改写 JS 字符串常量")
        check(AnalyzeUrl.substitute("{{searchKey}}/{{searchPage}}", key: "测试", page: 3) == "测试/3", "URL 模板保留搜索参数兼容别名")
        check(AnalyzeUrl.substitute("{{({searchKey: '保留字段'}).searchKey}}", key: "测试", page: 3) == "保留字段", "URL 模板不改写对象属性名")
        check(AnalyzeUrl.evalUrlJS("/search?q={{key}}", key: "测试", page: 1, baseUrl: "https://example.invalid/") == "/search?q={{key}}", "无 JS 的 URL 保持原文等待模板替换")
        check(AnalyzeUrl.evalUrlJS("/start<JS>result + '/next'</JS>", key: nil, page: 1, baseUrl: nil) == "/start/next", "URL JS 标签大小写不敏感")
        check(AnalyzeUrl.evalUrlJS("/start<js>result + '/middle'</js>@result/end", key: nil, page: 1, baseUrl: nil) == "/start/middle/end", "URL 后续字面量通过 @result 保留前段结果")
        check(AnalyzeUrl.evalUrlJS("/a<js>result + '/b'</js>@result/c<js>result + '/d'</js>", key: nil, page: 1, baseUrl: nil) == "/a/b/c/d", "多个 URL 脚本与字面量按出现顺序执行")
        check(AnalyzeUrl.evalUrlJS("@JS:key + '/' + page", key: "测试", page: 3, baseUrl: nil) == "测试/3", "URL @JS 前缀与请求参数绑定")
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
        var scopeA = dj
        var scopeB = dj
        let scopeBase = "https://scope.example.invalid/" + UUID().uuidString
        scopeA.bookSourceUrl = scopeBase + "#A"
        scopeB.bookSourceUrl = scopeBase + "#B"
        _ = RuleContext.sourcePut(scopeA.bookSourceUrl, "sourceOnly", "A")
        check(RuleContext.sourceGet(scopeB.bookSourceUrl, "sourceOnly") == "", "同站不同后缀书源的静态存储隔离")
        check(RuleContext(source: scopeA).get("sourceOnly") == "A", "来源静态存储与上下文读取一致")
        let sourceContext = RuleContext(source: scopeA)
        _ = sourceContext.put("shared", "source")
        check(RuleContext(source: scopeA).get("shared") == "source", "同一书源跨上下文保留来源变量")
        check(RuleContext(source: scopeB).get("shared") == "", "来源变量不泄漏到同站另一书源")
        let scopeBook = Book(bookUrl: scopeBase + "/book/1", name: "作用域测试", origin: scopeA.bookSourceUrl)
        let otherBook = Book(bookUrl: scopeBase + "/book/2", name: "另一书籍", origin: scopeA.bookSourceUrl)
        let bookContext = RuleContext(source: scopeA, book: scopeBook)
        _ = bookContext.put("shared", "book")
        check(RuleContext(source: scopeA, book: scopeBook).get("shared") == "book", "书籍变量跨上下文保留并覆盖来源值")
        check(RuleContext(source: scopeA, book: otherBook).get("shared") == "source", "不同书籍不共享书籍变量")
        let scopeChapter = BookChapter(url: scopeBase + "/chapter/1", title: "第一章", index: 0)
        let otherChapter = BookChapter(url: scopeBase + "/chapter/2", title: "第二章", index: 1)
        let chapterContext = RuleContext(source: scopeA, book: scopeBook, chapter: scopeChapter)
        _ = chapterContext.put("shared", "chapter")
        check(RuleContext(source: scopeA, book: scopeBook, chapter: scopeChapter).get("shared") == "chapter", "章节变量跨上下文保留并优先于书籍值")
        check(RuleContext(source: scopeA, book: scopeBook, chapter: otherChapter).get("shared") == "book", "不同章节回退书籍变量而不串值")
        check(chapterContext.get("bookName") == "作用域测试" && chapterContext.get("title") == "第一章", "保留书名与章节标题特殊变量")
        let secondChapterContext = RuleContext(source: scopeA, book: scopeBook, chapter: scopeChapter)
        _ = secondChapterContext.put("shared", "updated")
        check(chapterContext.get("shared") == "updated", "已有上下文可见其他上下文更新而不返回旧缓存")
        _ = secondChapterContext.put("shared", "")
        check(chapterContext.get("shared") == "book", "章节变量为空时回退书籍变量")
        _ = RuleContext(source: scopeA, book: scopeBook).put("shared", "")
        check(bookContext.get("shared") == "source", "书籍变量为空时回退来源变量")
        let switchedContext = RuleContext(source: scopeA, book: scopeBook)
        _ = switchedContext.put("onlyThisBook", "private")
        switchedContext.book = otherBook
        check(switchedContext.get("onlyThisBook") == "", "切换书籍后不残留前一本的实例变量")
        var sameURLDifferentSource = scopeBook
        sameURLDifferentSource.origin = scopeB.bookSourceUrl
        check(RuleContext(source: scopeB, book: sameURLDifferentSource).get("onlyThisBook") == "", "相同书籍 URL 在不同书源下仍然隔离")
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
        ParserRegression.run(check)
        JSBridgeRegression.run(check)
        BookContextRegression.run(check)
        BookInfoFallbackRegression.run(check)
        try await HTTPResponseRegression.run(check)
        CookieStoreRegression.run(check)
        try await CookieBridgeRegression.run(check)
        SourceLoginRegression.run(check)
        LoginBridgeRegression.run(check)
        PersistentLoginRegression.run(check)
        try CookieJarSwitchRegression.run(check)
        try TocParseRegression.run(check)
        try LoginFormRegression.run(check)
        try QimoSourceRegression.run(check)
        ContentBlocksRegression.run(check)
        CommentCardRegression.run(check)
        InlineBubbleRegression.run(check)
        ReadingPositionRegression.run(check)
        SearchRankingRegression.run(check)
        NextUrlRegression.run(check)
        CookieDomainRegression.run(check)
        SourceCryptoRegression.run(check)
        CryptoBridgeRegression.run(check)
        print("REGRESSION PASS: \(checks) 项固定断言；不声称真机网络/WebView 已验证。")
    }
}
