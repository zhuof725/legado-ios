import Foundation

/// 正文块：文字段落，或段评气泡/图片。从书源正文规则的输出解析而来。
/// 书源（如柒默的 iOS 版）在段落末尾输出 `<comment count="N" onClick="java.startBrowser('URL')"/>`，
/// 章末评论或精选评论则是 `<img src="data:image/svg+xml;base64,…" onClick="java.startBrowser('URL')"/>`。
enum ContentBlock: Equatable {
    case paragraph(text: String, commentCount: Int, commentURL: String?)
    case image(src: String, clickURL: String?)
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
        return blocks
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
                    blocks.append(.image(src: stripOptions(src), clickURL: clickURL(in: tag) ?? optionClick(in: src)))
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

    static func optionClick(in src: String) -> String? {
        guard src.contains(",{") else { return nil }
        return urlInCall(src)
    }

    /// 阅读缓存/兼容用：把块还原成与原来 cleanText 一致的纯文本（评论标记丢弃）。
    static func plainText(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .paragraph(let t, _, _) = b { return "\u{3000}\u{3000}" + t }
            return nil
        }.joined(separator: "\n")
    }
}
