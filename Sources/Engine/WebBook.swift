import Foundation

enum WebBook {
    // MARK: Search
    static func search(source: BookSource, key: String, page: Int = 1) async throws -> [Book] {
        guard let su = source.searchUrl, !su.isEmpty, let rule = source.ruleSearch else { return [] }
        let au = AnalyzeUrl(rawUrl: su, key: key, page: page, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: RuleContext(source: source), jsLib: source.jsLib)
        let (body, url) = try await au.fetch()
        return parseBookList(source: source, body: body, baseUrl: url, rule: rule)
    }

    static func parseBookList(source: BookSource, body: String, baseUrl: String, rule: SearchRule) -> [Book] {
        let ar = AnalyzeRule(content: body, baseUrl: baseUrl, jsLib: source.jsLib, context: RuleContext(source: source))
        let items = ar.getElements(rule.bookList)
        var out: [Book] = []
        for item in items {
            let name = ar.getString(rule.name, from: item)
            if name.isEmpty { continue }
            var bookUrl = ar.getString(rule.bookUrl, from: item)
            bookUrl = bookUrl.isEmpty ? baseUrl : AnalyzeUrl.absolute(bookUrl.components(separatedBy: "\n").first ?? bookUrl, base: baseUrl)
            var b = Book(bookUrl: bookUrl, name: name, origin: source.bookSourceUrl)
            b.originName = source.bookSourceName
            b.author = ar.getString(rule.author, from: item)
            b.intro = nilIfEmpty(ar.getString(rule.intro, from: item))
            b.kind = nilIfEmpty(ar.getString(rule.kind, from: item))
            b.lastChapter = nilIfEmpty(ar.getString(rule.lastChapter, from: item))
            b.wordCount = nilIfEmpty(ar.getString(rule.wordCount, from: item))
            let cover = ar.getString(rule.coverUrl, from: item)
            b.coverUrl = cover.isEmpty ? nil : AnalyzeUrl.absolute(cover, base: baseUrl)
            out.append(b)
        }
        return out
    }

    // MARK: Book info
    static func bookInfo(source: BookSource, book: Book) async throws -> Book {
        var b = book
        guard let rule = source.ruleBookInfo else { return b }
        let au = AnalyzeUrl(rawUrl: book.bookUrl, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: RuleContext(source: source, book: book), jsLib: source.jsLib)
        let (body, url) = try await au.fetch()
        let context = RuleContext(source: source, book: b)
        let ar = AnalyzeRule(content: body, baseUrl: url, jsLib: source.jsLib, context: context)
        var root: Any? = nil
        if let i = rule.`init`, !i.isEmpty {
            // Legado 的 init 既可能是纯文本/JS，也可能是 JSON 对象（如得间 body.bookInfo）。
            // 先从整页按字段规则取对象；取不到再退回整页 JS/文本。
            root = ar.getElements(i).first
            if root == nil {
                let initText = ar.getString(i)
                root = AnalyzeRule.parse(initText, baseUrl: url)
            }
            if let parsedString = AnalyzeRule.parse(AnalyzeRule.asString(root ?? ""), baseUrl: url) as? [String: Any] {
                root = parsedString
            } else if let parsedArray = AnalyzeRule.parse(AnalyzeRule.asString(root ?? ""), baseUrl: url) as? [Any] {
                root = parsedArray
            }
        }
        func s(_ r: String?) -> String { ar.getString(r, from: root) }
        let n = s(rule.name); if !n.isEmpty { b.name = n }
        let a = s(rule.author); if !a.isEmpty { b.author = a }
        if let v = nilIfEmpty(s(rule.intro)) { b.intro = v }
        if let v = nilIfEmpty(s(rule.kind)) { b.kind = v }
        if let v = nilIfEmpty(s(rule.lastChapter)) { b.lastChapter = v }
        if let v = nilIfEmpty(s(rule.wordCount)) { b.wordCount = v }
        if let v = nilIfEmpty(s(rule.coverUrl)) { b.coverUrl = AnalyzeUrl.absolute(v, base: url) }
        let toc = s(rule.tocUrl)
        b.tocUrl = toc.isEmpty ? url : AnalyzeUrl.absolute(toc, base: url)
        context.book = b
        return b
    }

    // MARK: TOC
    static func chapters(source: BookSource, book: Book) async throws -> [BookChapter] {
        guard let rule = source.ruleToc else { return [] }
        var next: String? = book.tocUrl ?? book.bookUrl
        var visited = Set<String>()
        var list: [BookChapter] = []
        var reverse = false
        var listRule = rule.chapterList ?? ""
        if listRule.hasPrefix("-") { reverse = true; listRule.removeFirst() }
        while let u = next, !u.isEmpty, !visited.contains(u), visited.count < 30 {
            visited.insert(u)
            let au = AnalyzeUrl(rawUrl: u, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: RuleContext(source: source, book: book), jsLib: source.jsLib)
            let (body, url) = try await au.fetch()
            let ar = AnalyzeRule(content: body, baseUrl: url, jsLib: source.jsLib, context: RuleContext(source: source, book: book))
            for item in ar.getElements(listRule) {
                let title = ar.getString(rule.chapterName, from: item)
                if title.isEmpty { continue }
                let vol = ar.getString(rule.isVolume, from: item)
                let isVol = vol == "true" || vol == "1"
                var cu = ar.getString(rule.chapterUrl, from: item)
                // 卷标题允许空 URL，普通章节必须有链接
                if cu.isEmpty {
                    if isVol {
                        cu = "" // 卷标题可以没有链接
                    } else {
                        continue // 跳过没有链接的普通章节
                    }
                } else {
                    cu = AnalyzeUrl.absolute(cu, base: url)
                }
                list.append(BookChapter(url: cu, title: title, index: 0, isVolume: isVol))
            }
            let n = ar.getString(rule.nextTocUrl).components(separatedBy: "\n").first ?? ""
            next = n.isEmpty ? nil : AnalyzeUrl.absolute(n, base: url)
        }
        if reverse { list.reverse() }
        for i in list.indices { list[i].index = i }
        return list
    }

    // MARK: Content
    static func content(source: BookSource, chapter: BookChapter, nextChapterUrl: String? = nil, book: Book? = nil) async throws -> String {
        guard let rule = source.ruleContent else { return "" }
        var next: String? = chapter.url
        var visited = Set<String>()
        var parts: [String] = []
        while let u = next, !u.isEmpty, !visited.contains(u), visited.count < 20 {
            if let nc = nextChapterUrl, u == nc, !visited.isEmpty { break }
            visited.insert(u)
            var au = AnalyzeUrl(rawUrl: u, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: RuleContext(source: source, book: book, chapter: chapter), jsLib: source.jsLib)
            if let wj = rule.webJs, !wj.isEmpty { au.webJs = wj }
            let (body, url) = try await au.fetch()
            let ar = AnalyzeRule(content: body, baseUrl: url, jsLib: source.jsLib, context: RuleContext(source: source, book: book))
            parts.append(ar.getString(rule.content))
            let n = ar.getString(rule.nextContentUrl).components(separatedBy: "\n").first ?? ""
            next = n.isEmpty ? nil : AnalyzeUrl.absolute(n, base: url)
        }
        var text = parts.joined(separator: "\n")
        if let rr = rule.replaceRegex, !rr.isEmpty {
            text = AnalyzeRule(content: text, baseUrl: chapter.url, context: RuleContext(source: source, chapter: chapter)).getString(rr.hasPrefix("##") ? rr : "##" + rr, from: text)
        }
        return cleanText(text)
    }

    static func cleanText(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
        return t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}"))) }
            .filter { !$0.isEmpty }
            .map { "\u{3000}\u{3000}" + $0 }
            .joined(separator: "\n")
    }

    static func nilIfEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}
