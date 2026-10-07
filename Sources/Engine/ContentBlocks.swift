import Foundation

/// 正文块：文字段落，或段评气泡/图片。从书源正文规则的输出解析而来。
/// 书源（如柒默的 iOS 版）在段落末尾输出 `<comment count="N" onClick="java.startBrowser('URL')"/>`，
/// 章末评论或精选评论则是 `<img src="data:image/svg+xml;base64,…" onClick="java.startBrowser('URL')"/>`。
enum ContentBlock: Equatable {
    case paragraph(text: String, commentCount: Int, commentURL: String?)
    /// 行内小图（书源 `style:"text"` 的气泡图）：按文字大小显示在上一段末尾。
    /// src 是 data: 或网址；count 是气泡里的数字（从 SVG 文本里读出，读不到为 nil）。
    case inlineBubble(src: String, count: Int?, clickURL: String?)
    case image(src: String, clickURL: String?)
    /// 书源用 SVG 画的「热评」卡片，改用原生卡片显示：label 为红色标签文字，text 为评论内容。
    case hotComment(label: String, text: String, clickURL: String?)
    /// 章末「本章说」评论汇总：标题、右侧计数文字，以及若干条 用户名/正文/点赞数。
    case chapterComments(title: String, count: String, items: [ChapterCommentItem], clickURL: String?)
}

struct ChapterCommentItem: Equatable {
    var user: String
    var text: String
    var likes: String
}

enum ContentBlocks {
    /// 把规则输出拆成有序块。普通文本（没有任何评论标签）得到只含 paragraph 的块，与原来的 cleanText 逐行一致。
    static func parse(_ raw: String) -> [ContentBlock] {
        var text = raw
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        var blocks: [ContentBlock] = []
        for line in text.components(separatedBy: .newlines) {
            appendLine(line, into: &blocks)
        }
        return mergeInlineBubbles(blocks)
    }

    /// 把行内气泡并入它前面的段落（count 与点击目标取自气泡）。前面不是段落时，丢弃该气泡。
    static func mergeInlineBubbles(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var out: [ContentBlock] = []
        for b in blocks {
            if case .inlineBubble(_, let count, let click) = b {
                if case .paragraph(let t, let c, let u)? = out.last {
                    out[out.count - 1] = .paragraph(text: t, commentCount: count ?? max(c, 1), commentURL: click ?? u)
                }
            } else {
                out.append(b)
            }
        }
        return out
    }

    private static let tagPattern = try! NSRegularExpression(pattern: "<(comment|img)\\b[^>]*?/?>", options: [.caseInsensitive])

    private static func appendLine(_ line: String, into blocks: inout [ContentBlock]) {
        let ns = line as NSString
        let matches = tagPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var cursor = 0
        var pendingText = ""
        var pendingCount = 0
        var pendingURL: String?
        func flush() {
            let t = clean(pendingText)
            if !t.isEmpty || pendingCount > 0 {
                if t.isEmpty && pendingCount > 0, case .paragraph(let prev, let c, let u)? = blocks.last, c == 0, u == nil {
                    blocks[blocks.count - 1] = .paragraph(text: prev, commentCount: pendingCount, commentURL: pendingURL)
                } else if !t.isEmpty {
                    blocks.append(.paragraph(text: t, commentCount: pendingCount, commentURL: pendingURL))
                }
            }
            pendingText = ""; pendingCount = 0; pendingURL = nil
        }
        for m in matches {
            pendingText += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let tag = ns.substring(with: m.range)
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if name == "comment" {
                pendingCount = Int(attribute("count", in: tag) ?? "") ?? 0
                pendingURL = clickURL(in: tag)
            } else {
                // 图片是独立块：先结束当前段落。
                flush()
                if let src = attribute("src", in: tag), !src.isEmpty {
                    let clean = stripOptions(src)
                    let opts = srcOptions(src)
                    let click = clickURL(in: tag) ?? optionClick(in: src) ?? clickFromOptions(opts)
                    if opts["style"]?.lowercased() == "text" {
                        // 书源要求按文字大小行内显示：接到上一段末尾，而不是单独成大图。
                        blocks.append(.inlineBubble(src: clean, count: svgTexts(svgText(clean) ?? "").compactMap { Int($0) }.first, clickURL: click))
                    } else if let svg = svgText(clean), let native = nativeBlock(fromSVG: svg, click: click) {
                        blocks.append(native)
                    } else {
                        blocks.append(.image(src: clean, clickURL: click))
                    }
                }
            }
        }
        pendingText += ns.substring(from: cursor)
        flush()
    }

    private static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, d) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: d)
        }
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}")))
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1...2 where m.range(at: i).location != NSNotFound {
            return (tag as NSString).substring(with: m.range(at: i))
        }
        return nil
    }

    /// onClick="java.startBrowser('https://…')" -> https://…
    static func clickURL(in tag: String) -> String? {
        guard let click = attribute("onClick", in: tag) else { return nil }
        return urlInCall(click)
    }

    static func urlInCall(_ call: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "startBrowser(?:Await)?\\(\\s*['\"]([^'\"]+)['\"]"),
              let m = re.firstMatch(in: call, range: NSRange(location: 0, length: (call as NSString).length)) else { return nil }
        return (call as NSString).substring(with: m.range(at: 1))
    }

    /// src 后面可能带 `,{"type":..,"click":"java.startBrowser('…')"}` 选项（Android 版）。
    static func stripOptions(_ src: String) -> String {
        if let r = src.range(of: ",{") { return String(src[..<r.lowerBound]) }
        return src
    }

    /// src 后面 `,{"style":"text","type":"qd","click":"showCmt('1','2','3','4')"}` 的键值（字符串值）。
    static func srcOptions(_ src: String) -> [String: String] {
        guard let r = src.range(of: ",{") else { return [:] }
        let json = String(src[src.index(after: r.lowerBound)...])
        if let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            return o.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        }
        // 书源常写成 {"style":"text","click":"showCmt('1')"} 里含未转义引号的写法：退回逐键提取。
        var out: [String: String] = [:]
        for key in ["style", "type", "click"] {
            if let re = try? NSRegularExpression(pattern: "\"" + key + "\"\\s*:\\s*\"(.*?)\"(?:\\s*[,}])"),
               let m = re.firstMatch(in: json, range: NSRange(location: 0, length: (json as NSString).length)) {
                out[key] = (json as NSString).substring(with: m.range(at: 1))
            }
        }
        return out
    }

    /// click 是 JS 调用（如 showCmt('书','章','段','数')）时，不是网址；留给调用方按书源执行。
    static func clickFromOptions(_ opts: [String: String]) -> String? {
        guard let c = opts["click"], !c.isEmpty else { return nil }
        if let u = urlInCall(c) { return u }
        return "js:" + c
    }

    static func optionClick(in src: String) -> String? {
        guard src.contains(",{") else { return nil }
        return urlInCall(src)
    }

    // MARK: - SVG 评论卡片 -> 原生块

    /// 解出 data:image/svg+xml 的 SVG 文本；不是 SVG 返回 nil。
    static func svgText(_ src: String) -> String? {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let meta = src[..<comma].lowercased()
        guard meta.contains("svg") else { return nil }
        let payload = String(src[src.index(after: comma)...])
        if meta.contains(";base64") {
            var p = payload.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
            while p.count % 4 != 0 { p += "=" }
            guard let d = Data(base64Encoded: p) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        return payload.removingPercentEncoding
    }

    private static func xmlUnescape(_ s: String) -> String {
        var t = s
        for (e, d) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: e, with: d)
        }
        return t
    }

    /// SVG 里所有 <text> 的内容，保持出现顺序。
    static func svgTexts(_ svg: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<text\\b[^>]*>([^<]*)</text>", options: [.caseInsensitive]) else { return [] }
        let ns = svg as NSString
        return re.matches(in: svg, range: NSRange(location: 0, length: ns.length)).map {
            xmlUnescape(ns.substring(with: $0.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 识别书源生成的两类评论 SVG：热评（标签+一行）与「本章说」汇总。其他 SVG 返回 nil，仍按图片显示。
    static func nativeBlock(fromSVG svg: String, click: String?) -> ContentBlock? {
        let texts = svgTexts(svg)
        if texts.count == 2, texts[0] == "热评" {
            return .hotComment(label: texts[0], text: texts[1], clickURL: click)
        }
        if texts.count >= 2, texts[0] == "本章说" {
            // 后面是 用户名、(点赞数 在图形里)、正文行… 的重复；书源把正文按行切成多个 <text>。
            // 这里只可靠地得到标题和计数；条目不再还原，点击进入评论页查看。
            return .chapterComments(title: texts[0], count: texts[1], items: [], clickURL: click)
        }
        return nil
    }

    /// 阅读缓存/兼容用：把块还原成与原来 cleanText 一致的纯文本（评论标记丢弃）。
    static func plainText(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .paragraph(let t, _, _) = b { return "\u{3000}\u{3000}" + t }
            return nil
        }.joined(separator: "\n")
    }
}
