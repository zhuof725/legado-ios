import Foundation

/// 本地书：TXT 与 EPUB 导入。解析出的章节正文保存在本地缓存里，阅读器按 `local://` 地址读取。
struct LocalChapter: Equatable { var title: String; var text: String }
struct LocalBookData: Equatable {
    var title: String
    var author: String
    var chapters: [LocalChapter]
    var coverData: Data?

    static func == (a: LocalBookData, b: LocalBookData) -> Bool {
        a.title == b.title && a.author == b.author && a.chapters == b.chapters
    }
}

enum LocalBookError: Error, Equatable { case unreadable, empty, unsupported(String) }

enum LocalBook {
    // MARK: 编码识别

    /// UTF-8（含 BOM）-> UTF-16（有 BOM）-> GB18030 -> 兜底宽松 UTF-8。
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        if let s = String(data: data, encoding: big5) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: TXT

    /// 常见章节标题：第X章/节/回/卷/集/部、Chapter N、序章/楔子/番外/后记。整行较短才算标题。
    private static let titlePattern = try! NSRegularExpression(
        pattern: "^\\s*(第\\s*[0-9零一二三四五六七八九十百千万两〇]+\\s*[章节回卷集部篇].{0,40}|(?i:chapter)\\s*[0-9]+.{0,40}|(序章|楔子|引子|前言|后记|尾声|番外).{0,30})\\s*$")

    static func isChapterTitle(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 50 else { return false }
        return titlePattern.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
    }

    static func parseTXT(_ data: Data, fileName: String) throws -> LocalBookData {
        guard var text = decode(data), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalBookError.empty }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let name = (fileName as NSString).deletingPathExtension
        var title = name, author = ""
        // 「《书名》作者：xxx」「书名 作者 xxx」这类文件名
        if let m = try? NSRegularExpression(pattern: "《(.+?)》\\s*(?:作者[：:\\s]*|by\\s*)?(.*)$").firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) {
            title = (name as NSString).substring(with: m.range(at: 1))
            author = (name as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
        }
        var chapters: [LocalChapter] = []
        var curTitle: String?
        var buf: [String] = []
        func flush() {
            let body = buf.map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}"))) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            if let t = curTitle { chapters.append(LocalChapter(title: t, text: body)) }
            else if !body.isEmpty { chapters.append(LocalChapter(title: "前言", text: body)) }
            buf = []
        }
        for line in text.components(separatedBy: "\n") {
            if isChapterTitle(line) { flush(); curTitle = line.trimmingCharacters(in: .whitespaces) } else { buf.append(line) }
        }
        flush()
        // 没识别出任何章节标题：按固定字数切段，避免整本是一章。
        if chapters.count <= 1 {
            chapters = splitBySize(text, size: 5000)
        }
        chapters = chapters.filter { !$0.text.isEmpty || !$0.title.isEmpty }
        guard !chapters.isEmpty else { throw LocalBookError.empty }
        return LocalBookData(title: title, author: author, chapters: chapters, coverData: nil)
    }

    /// 在行边界附近按字数切章。
    static func splitBySize(_ text: String, size: Int) -> [LocalChapter] {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [LocalChapter] = []
        var cur: [String] = []
        var n = 0
        for l in lines {
            cur.append(l); n += l.count
            if n >= size { out.append(LocalChapter(title: "第 \(out.count + 1) 部分", text: cur.joined(separator: "\n"))); cur = []; n = 0 }
        }
        if !cur.isEmpty { out.append(LocalChapter(title: "第 \(out.count + 1) 部分", text: cur.joined(separator: "\n"))) }
        return out
    }

    // MARK: EPUB

    static func parseEPUB(_ data: Data, fileName: String) throws -> LocalBookData {
        let zip: ZipReader
        do { zip = try ZipReader(data: data) } catch { throw LocalBookError.unreadable }
        guard let container = try? zip.read("META-INF/container.xml"),
              let cs = String(data: container, encoding: .utf8),
              let opfPath = attr("full-path", inTag: "rootfile", in: cs),
              let opfData = try? zip.read(opfPath), let opf = String(data: opfData, encoding: .utf8) else {
            throw LocalBookError.unreadable
        }
        let base = (opfPath as NSString).deletingLastPathComponent
        func resolve(_ href: String) -> String {
            let h = href.removingPercentEncoding ?? href
            let path = base.isEmpty ? h : base + "/" + h
            return normalize(path)
        }
        let title = firstText(tag: "dc:title", in: opf) ?? (fileName as NSString).deletingPathExtension
        let author = firstText(tag: "dc:creator", in: opf) ?? ""

        // manifest: id -> (href, type, properties)
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        for tag in tags("item", in: opf) {
            if let id = attr("id", inTag: nil, in: tag), let href = attr("href", inTag: nil, in: tag) {
                manifest[id] = (href, attr("media-type", inTag: nil, in: tag) ?? "", attr("properties", inTag: nil, in: tag) ?? "")
            }
        }
        // spine 顺序
        let spineIDs = tags("itemref", in: opf).compactMap { attr("idref", inTag: nil, in: $0) }
        // 目录标题：EPUB3 nav 或 EPUB2 ncx
        var tocTitles: [String: String] = [:]
        if let nav = manifest.values.first(where: { $0.props.contains("nav") }), let d = try? zip.read(resolve(nav.href)), let s = String(data: d, encoding: .utf8) {
            let navBase = (resolve(nav.href) as NSString).deletingLastPathComponent
            for a in tags("a", in: s, withClose: true) {
                if let href = attr("href", inTag: nil, in: a.open) {
                    let key = normalize((navBase.isEmpty ? "" : navBase + "/") + (href.components(separatedBy: "#").first ?? href).removingPercentEncoding!)
                    if tocTitles[key] == nil { tocTitles[key] = stripTags(a.inner) }
                }
            }
        } else if let ncx = manifest.values.first(where: { $0.type.contains("ncx") }), let d = try? zip.read(resolve(ncx.href)), let s = String(data: d, encoding: .utf8) {
            let ncxBase = (resolve(ncx.href) as NSString).deletingLastPathComponent
            for np in blocks("navPoint", in: s) {
                if let label = firstText(tag: "text", in: np), let src = attr("src", inTag: "content", in: np) {
                    let key = normalize((ncxBase.isEmpty ? "" : ncxBase + "/") + (src.components(separatedBy: "#").first ?? src).removingPercentEncoding!)
                    if tocTitles[key] == nil { tocTitles[key] = label }
                }
            }
        }
        var chapters: [LocalChapter] = []
        var coverData: Data?
        for id in spineIDs {
            guard let item = manifest[id], item.type.contains("html") || item.type.contains("xml") else { continue }
            let path = resolve(item.href)
            guard let d = try? zip.read(path), let html = decode(d) else { continue }
            let text = htmlToText(html)
            if text.isEmpty { continue }
            let heading = firstHeading(in: html)
            let t = tocTitles[path] ?? heading ?? "第 \(chapters.count + 1) 章"
            chapters.append(LocalChapter(title: t, text: text))
        }
        // 封面
        if let coverItem = manifest.values.first(where: { $0.props.contains("cover-image") })
            ?? tags("meta", in: opf).compactMap({ t -> (href: String, type: String, props: String)? in
                guard attr("name", inTag: nil, in: t) == "cover", let cid = attr("content", inTag: nil, in: t) else { return nil }
                return manifest[cid]
            }).first {
            coverData = try? zip.read(resolve(coverItem.href))
        }
        guard !chapters.isEmpty else { throw LocalBookError.empty }
        return LocalBookData(title: title, author: author, chapters: chapters, coverData: coverData)
    }

    // MARK: 文本/HTML 工具

    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(p))
        }
        return parts.joined(separator: "/")
    }

    static func htmlToText(_ html: String) -> String {
        var t = html
        t = t.replacingOccurrences(of: "<(script|style)[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<head[\\s\\S]*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "</(p|div|h[1-6]|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = unescape(t)
        return t.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}"))) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func unescape(_ s: String) -> String {
        var t = s
        for (e, d) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ldquo;", "“"), ("&rdquo;", "”")] {
            t = t.replacingOccurrences(of: e, with: d)
        }
        // 数字实体 &#123; / &#x1F;
        if let re = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = t as NSString
            var out = ""; var last = 0
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let raw = ns.substring(with: m.range(at: 1))
                let v = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let v = v, let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t
    }

    static func stripTags(_ s: String) -> String {
        unescape(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstHeading(in html: String) -> String? {
        for tag in ["h1", "h2", "h3", "title"] {
            if let t = firstText(tag: tag, in: html), !t.isEmpty { return t }
        }
        return nil
    }

    static func firstText(tag: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*>([\\s\\S]*?)</\(tag)>", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else { return nil }
        let v = stripTags((s as NSString).substring(with: m.range(at: 1)))
        return v.isEmpty ? nil : v
    }

    /// 取出所有开始标签文本（含自闭合），如 <item id=".." href=".."/>。
    static func tags(_ name: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func tags(_ name: String, in s: String, withClose: Bool) -> [(open: String, inner: String)] {
        guard let re = try? NSRegularExpression(pattern: "(<\(name)\\b[^>]*>)([\\s\\S]*?)</\(name)>", options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    static func blocks(_ name: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<\(name)\\b[\\s\\S]*?</\(name)>", options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// 取属性值；inTag 非空时先定位到该标签。
    static func attr(_ name: String, inTag tag: String?, in s: String) -> String? {
        var scope = s
        if let tag = tag {
            guard let t = tags(tag, in: s).first else { return nil }
            scope = t
        }
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: [.caseInsensitive]),
              let m = re.firstMatch(in: scope, range: NSRange(location: 0, length: (scope as NSString).length)) else { return nil }
        for i in 1...2 where m.range(at: i).location != NSNotFound { return (scope as NSString).substring(with: m.range(at: i)) }
        return nil
    }
}
