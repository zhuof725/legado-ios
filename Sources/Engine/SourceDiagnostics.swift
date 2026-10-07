import Foundation

enum SourceDiagnostics {
    static func run(source: BookSource, keyword: String, bookURL: String) async {
        DebugLog.add("应用 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "测试工具") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
        DebugLog.add("书源：\(source.bookSourceName)")
        DebugLog.add("单独执行，不从书架缓存取目录，不改书源配置。")
        do {
            var book: Book
            if !bookURL.isEmpty {
                DebugLog.add("【跳过搜索，调试指定书籍】\(DebugLog.url(bookURL))")
                book = Book(bookUrl: bookURL, name: "调试书籍", origin: source.bookSourceUrl)
                book.originName = source.bookSourceName
            } else {
                guard let raw = source.searchUrl, let rule = source.ruleSearch else {
                    DebugLog.add("缺少搜索 URL 或搜索规则"); return
                }
                DebugLog.add("【搜索】关键词：\(keyword)")
                let context = RuleContext(source: source)
                let au = AnalyzeUrl(rawUrl: raw, key: keyword, page: 1, baseUrl: source.bookSourceUrl,
                                    sourceHeader: source.header, context: context, jsLib: source.jsLib)
                let (body, finalURL) = try await au.fetch()
                let ar = AnalyzeRule(content: body, baseUrl: finalURL, jsLib: source.jsLib, context: context)
                let nodes = ar.getElements(rule.bookList)
                DebugLog.add("书籍列表规则：\(rule.bookList ?? "空")")
                DebugLog.add("书籍列表匹配：\(nodes.count) 个节点")
                if let node = nodes.first {
                    DebugLog.add("第一个节点解析出的书名：\(ar.getString(rule.name, from: node))")
                }
                let books = WebBook.parseBookList(source: source, body: body, baseUrl: finalURL, rule: rule, context: context)
                DebugLog.add("解析成书籍：\(books.count) 本")
                guard let first = books.first(where: { $0.name.contains(keyword) }) ?? books.first else {
                    DebugLog.add("搜索无结果：请发送这段日志的截图；当前没有测试详情/目录/正文。")
                    return
                }
                book = first
                DebugLog.add("首本：\(book.name)；\(DebugLog.url(book.bookUrl))")
            }
            DebugLog.add("【详情】")
            let info = try await WebBook.bookInfo(source: source, book: book)
            DebugLog.add("详情书名：\(info.name)")
            DebugLog.add("简介：\(info.intro?.count ?? 0) 字符")
            DebugLog.add("目录URL：\(DebugLog.url(info.tocUrl ?? info.bookUrl))")
            DebugLog.add("【目录】")
            let chapters = try await WebBook.chapters(source: source, book: info)
            DebugLog.add("目录条目：\(chapters.count)；可读章节：\(chapters.filter { !$0.isVolume && !$0.url.isEmpty }.count)")
            guard let chapter = chapters.first(where: { !$0.isVolume && !$0.url.isEmpty }) else {
                DebugLog.add("目录为空：请发送日志截图。没有把目录页当正文。")
                return
            }
            DebugLog.add("首章：\(chapter.title)；\(DebugLog.url(chapter.url))")
            DebugLog.add("【正文】")
            let next = chapters.first { $0.index > chapter.index && !$0.isVolume && !$0.url.isEmpty }?.url
            let text = try await WebBook.content(source: source, chapter: chapter, nextChapterUrl: next, book: info)
            DebugLog.add("正文：\(text.count) 字符（不记录正文内容）")
            DebugLog.add(text.isEmpty ? "正文仍然为空" : "单本首章链路通过；不代表所有书籍/所有分页均已验证。")
        } catch {
            let ns = error as NSError
            DebugLog.add("错误：\(ns.domain) / \(ns.code)；\(String(error.localizedDescription.prefix(180)))")
        }
    }
}
