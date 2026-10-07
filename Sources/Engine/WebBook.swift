import Foundation

enum WebBook {
    // MARK: Search
    static func search(source: BookSource, key: String, page: Int = 1) async throws -> [Book] {
        guard let su = source.searchUrl, !su.isEmpty, let rule = source.ruleSearch else { return [] }
        let context = RuleContext(source: source)
        let au = AnalyzeUrl(rawUrl: su, key: key, page: page, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: context, jsLib: source.jsLib)
        let (body, url) = try await au.fetch()
        return parseBookList(source: source, body: body, baseUrl: url, rule: rule, context: context)
    }

    /// 与 Kotlin 的 `String.matches(Regex)` 一致：必须整串匹配。
    static func matchesWholly(_ text: String, pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$") else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 搜索结果页本身就是详情页时（站点精确匹配后跳转），按详情规则取出这一本书。
    static func bookFromInfoPage(source: BookSource, body: String, url: String, listContext: RuleContext) -> [Book] {
        var b = Book(bookUrl: url, name: "", origin: source.bookSourceUrl)
        b.originName = source.bookSourceName
        let infoContext = listContext.forkForBook(b)
        let parsed = parseBookInfo(source: source, book: b, body: body, url: url, context: infoContext)
        // 详情解析会把 tocUrl 兜底成当前页；这里只需要一条搜索结果。
        return parsed.name.isEmpty ? [] : [parsed]
    }

    static func parseBookList(source: BookSource, body: String, baseUrl: String, rule: SearchRule, context: RuleContext? = nil, isSearch: Bool = true) -> [Book] {
        let listContext = context ?? RuleContext(source: source)
        let hasPattern = !(source.bookUrlPattern ?? "").isEmpty
        if isSearch, hasPattern, let pattern = source.bookUrlPattern, matchesWholly(baseUrl, pattern: pattern) {
            DebugLog.add("链接为详情页（bookUrlPattern 命中）")
            return bookFromInfoPage(source: source, body: body, url: baseUrl, listContext: listContext)
        }
        let ar = AnalyzeRule(content: body, baseUrl: baseUrl, jsLib: source.jsLib, context: listContext)
        let items = ar.getElements(rule.bookList)
        if items.isEmpty, !hasPattern {
            DebugLog.add("列表为空，按详情页解析")
            return bookFromInfoPage(source: source, body: body, url: baseUrl, listContext: listContext)
        }
        // 冻结列表阶段变量；每个条目再独立派生，避免循环中的写入串书。
        let snapshot = listContext.forkForBook(Book(bookUrl: "", name: "", origin: source.bookSourceUrl))
        var out: [Book] = []
        for item in items {
            var b = Book(bookUrl: "", name: "", origin: source.bookSourceUrl)
            b.originName = source.bookSourceName
            let itemContext = snapshot.forkForBook(b)
            let itemRule = AnalyzeRule(content: item, baseUrl: baseUrl, jsLib: source.jsLib, context: itemContext)
            // 与 Kotlin getSearchItem 一致；每个字段完成后同步值类型 Book。
            b.name = itemRule.getString(rule.name)
            itemContext.book = b
            if b.name.isEmpty { continue }
            b.author = itemRule.getString(rule.author)
            itemContext.book = b
            b.kind = nilIfEmpty(itemRule.getString(rule.kind))
            itemContext.book = b
            b.wordCount = nilIfEmpty(itemRule.getString(rule.wordCount))
            itemContext.book = b
            b.lastChapter = nilIfEmpty(itemRule.getString(rule.lastChapter))
            itemContext.book = b
            b.intro = nilIfEmpty(itemRule.getString(rule.intro))
            itemContext.book = b
            let cover = itemRule.getString(rule.coverUrl)
            b.coverUrl = cover.isEmpty ? nil : AnalyzeUrl.absolute(cover, base: baseUrl)
            itemContext.book = b
            let bookUrl = itemRule.getString(rule.bookUrl)
            b.bookUrl = bookUrl.isEmpty ? baseUrl : AnalyzeUrl.absolute(bookUrl.components(separatedBy: "\n").first ?? bookUrl, base: baseUrl)
            itemContext.bindBook(b)
            out.append(b)
        }
        return out
    }

    // MARK: Book info
    static func bookInfo(source: BookSource, book: Book) async throws -> Book {
        var b = book
        guard let rule = source.ruleBookInfo else { return b }
        let context = RuleContext(source: source, book: b)
        let au = AnalyzeUrl(rawUrl: book.bookUrl, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: context, jsLib: source.jsLib)
        let (body, url) = try await au.fetch()
        return parseBookInfo(source: source, book: b, body: body, url: url, context: context)
    }

    /// 解析详情页内容。bookInfo 与“搜索结果直接是详情页”两条路径共用。
    static func parseBookInfo(source: BookSource, book: Book, body: String, url: String, context: RuleContext) -> Book {
        var b = book
        guard let rule = source.ruleBookInfo else { return b }
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
        if let root = root {
            if let dict = root as? [String: Any] {
                DebugLog.add("详情 init 字段：" + dict.keys.sorted().joined(separator: ", "))
            } else { DebugLog.add("详情 init 类型：\(type(of: root))") }
        } else if rule.`init`?.isEmpty == false {
            DebugLog.add("详情 init 未匹配，后续字段仍使用原响应")
        }
        func s(_ r: String?) -> String { ar.getString(r, from: root) }
        let n = s(rule.name); if !n.isEmpty { b.name = n }
        let a = s(rule.author); if !a.isEmpty { b.author = a }
        if let v = nilIfEmpty(s(rule.intro)) { b.intro = displayIntro(v) }
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
        // 与 Legado BookChapterList 一致：nextTocUrl 返回多个地址时全部抓取（不再逐页追链）；
        // 只有一个地址时沿链继续。待抓取队列去重，最多 30 页。
        var queue: [String] = []
        if let first = next, !first.isEmpty { queue.append(first) }
        while !queue.isEmpty, visited.count < 30 {
            let u = queue.removeFirst()
            if u.isEmpty || visited.contains(u) { continue }
            visited.insert(u)
            let context = RuleContext(source: source, book: book)
            let au = AnalyzeUrl(rawUrl: u, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: context, jsLib: source.jsLib)
            let (body, url) = try await au.fetch()
            let ar = AnalyzeRule(content: body, baseUrl: url, jsLib: source.jsLib, context: context)
            let nodes = ar.getElements(listRule)
            DebugLog.add("目录列表匹配：\(nodes.count) 项（第\(visited.count)页）")
            list.append(contentsOf: parseChapterNodes(nodes, rule: rule, ar: ar, baseUrl: url))
            let urls = splitNextUrls(ar.getString(rule.nextTocUrl), base: url)
            for n in urls where !visited.contains(n) && !queue.contains(n) { queue.append(n) }
        }
        // Legado 以 url 判等，LinkedHashSet 去重并保留首次出现；空 URL 的卷标题不参与去重。
        list = dedupeChapters(list)
        if reverse { list.reverse() }
        for i in list.indices { list[i].index = i }
        return list
    }

    /// nextTocUrl / nextContentUrl 可能返回多行地址：去空白、转绝对地址、去重并保持顺序。
    static func splitNextUrls(_ raw: String, base: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let u = AnalyzeUrl.absolute(t, base: base)
            if seen.insert(u).inserted { out.append(u) }
        }
        return out
    }

    /// 把目录列表节点解析成章节（不含去重与反转），便于离线测试。
    static func parseChapterNodes(_ nodes: [Any], rule: TocRule, ar: AnalyzeRule, baseUrl url: String) -> [BookChapter] {
        var out: [BookChapter] = []
        for item in nodes {
            let title = ar.getString(rule.chapterName, from: item)
            if title.isEmpty { continue }
            let vol = ar.getString(rule.isVolume, from: item)
            let isVol = vol == "true" || vol == "1"
            var cu = ar.getString(rule.chapterUrl, from: item)
            if cu.isEmpty {
                if !isVol { continue } // 普通章节必须有链接；卷标题可以没有
            } else {
                cu = AnalyzeUrl.absolute(cu, base: url)
            }
            var chapter = BookChapter(url: cu, title: title, index: 0, isVolume: isVol)
            if let vr = rule.isVip, !vr.isEmpty { chapter.isVip = isTruthy(ar.getString(vr, from: item)) }
            if let ur = rule.updateTime, !ur.isEmpty {
                chapter.updateTime = nilIfEmpty(ar.getString(ur, from: item))
            }
            out.append(chapter)
        }
        return out
    }

    /// 与 Legado 对 isVip/isPay/isVolume 的判定一致：空、false、0、null 为假，其余为真。
    static func isTruthy(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(t.isEmpty || t == "false" || t == "0" || t == "null" || t == "undefined")
    }

    /// Legado 以章节 url 为键，用 LinkedHashSet 保留首次出现；空 URL 的卷标题不参与去重。
    static func dedupeChapters(_ list: [BookChapter]) -> [BookChapter] {
        var seen = Set<String>()
        return list.filter { $0.url.isEmpty || seen.insert($0.url).inserted }
    }

    // MARK: Content
    static func content(source: BookSource, chapter: BookChapter, nextChapterUrl: String? = nil, book: Book? = nil) async throws -> String {
        let raw = try await rawContent(source: source, chapter: chapter, nextChapterUrl: nextChapterUrl, book: book)
        return cleanText(raw)
    }

    /// 与 content 相同的抓取流程，但保留 <comment>/<img> 标记，供阅读器渲染段评。
    static func contentBlocks(source: BookSource, chapter: BookChapter, nextChapterUrl: String? = nil, book: Book? = nil) async throws -> (raw: String, blocks: [ContentBlock]) {
        let raw = try await rawContent(source: source, chapter: chapter, nextChapterUrl: nextChapterUrl, book: book)
        return (raw, ContentBlocks.parse(raw))
    }

    /// 书源 loginUi 是脚本时，里面常有 java.put('dev', …) 之类的初始化（Legado 打开登录页时才执行）。
    /// 正文规则会读取这些变量，所以抓取前先求值一次，把变量写进书源作用域。每个书源每次启动只执行一次。
    private static var loginUiPrimed = Set<String>()
    private static let primeLock = NSLock()
    static func primeLoginUi(_ source: BookSource) {
        guard let ui = source.loginUi, !ui.isEmpty else { return }
        let raw = ui.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard raw.hasPrefix("@js:") || raw.hasPrefix("<js>") else { return }
        primeLock.lock()
        let first = loginUiPrimed.insert(source.bookSourceUrl).inserted
        primeLock.unlock()
        guard first else { return }
        _ = SourceLoginForm.resolveUiText(ui) { js in
            JSEngine.shared.evalString(js, jsLib: source.jsLib, context: RuleContext(source: source))
        }
    }

    static func rawContent(source: BookSource, chapter: BookChapter, nextChapterUrl: String? = nil, book: Book? = nil) async throws -> String {
        primeLoginUi(source)
        guard let rule = source.ruleContent else { return "" }
        var visited = Set<String>()
        var parts: [String] = []
        /// 抓取一页，返回正文与解析出的下一页地址（已过滤、转绝对地址）。
        func loadPage(_ u: String) async throws -> (String, [String]) {
            visited.insert(u)
            let context = RuleContext(source: source, book: book, chapter: chapter)
            var au = AnalyzeUrl(rawUrl: u, baseUrl: source.bookSourceUrl, sourceHeader: source.header, context: context, jsLib: source.jsLib)
            if let wj = rule.webJs, !wj.isEmpty { au.webJs = wj }
            let (body, url) = try await au.fetch()
            let ar = AnalyzeRule(content: body, baseUrl: url, jsLib: source.jsLib, context: context)
            let text = ar.getString(rule.content)
            let urls = splitNextUrls(ar.getString(rule.nextContentUrl), base: url)
            return (text, urls)
        }
        let first = try await loadPage(chapter.url)
        parts.append(first.0)
        // 与 Legado BookContent 一致：下一页地址若是下一章则停止；
        // 只有一个地址时沿链追到末页；多个地址时按顺序各取一页，不再继续追链。
        let pending = first.1.filter { $0 != nextChapterUrl && !visited.contains($0) }
        if pending.count == 1 {
            var cur: String? = pending[0]
            while let u = cur, !visited.contains(u), u != nextChapterUrl, visited.count < 20 {
                let page = try await loadPage(u)
                parts.append(page.0)
                let more = page.1.filter { $0 != nextChapterUrl && !visited.contains($0) }
                cur = more.first
            }
        } else if pending.count > 1 {
            for u in pending.prefix(19) where !visited.contains(u) {
                try Task.checkCancellation()
                parts.append(try await loadPage(u).0)
            }
        }
        var text = parts.joined(separator: "\n")
        if let rr = rule.replaceRegex, !rr.isEmpty {
            text = AnalyzeRule(content: text, baseUrl: chapter.url, jsLib: source.jsLib, context: RuleContext(source: source, book: book, chapter: chapter)).getString(rr.hasPrefix("##") ? rr : "##" + rr, from: text)
        }
        return text
    }

    static func displayIntro(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "<br\\s*/?>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, decoded) in [("&nbsp;", " "), ("&shy;", ""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\"")] {
            value = value.replacingOccurrences(of: entity, with: decoded)
        }
        return value.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
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
