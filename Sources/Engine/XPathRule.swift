import Foundation
import Kanna
import SwiftSoup

/// Legado XPath 规则：必须以 @XPath: 或 // 开头（教程「语法说明 - XPath」）。
/// 兼容 JsoupXpath 的扩展函数：/text()、/html()、/allText()、/textNodes()、/@attr。
enum XPathRule {
    static func isXPath(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.lowercased().hasPrefix("@xpath:") || t.hasPrefix("//")
    }

    static func strip(_ rule: String) -> String {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.lowercased().hasPrefix("@xpath:") ? String(t.dropFirst(7)) : t
    }

    /// 把当前对象转成可供 XPath 解析的 HTML
    static func html(of obj: Any) -> String {
        var s: String
        if let e = obj as? Element { s = (try? e.outerHtml()) ?? "" }
        else if let str = obj as? String { s = str }
        else { s = AnalyzeRule.asString(obj) }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4).lowercased()
        // 表格片段脱离 <table> 会被 HTML 解析器丢弃
        if head.hasPrefix("<tr") || head.hasPrefix("<td") || head.hasPrefix("<th") || head.hasPrefix("<tb") {
            s = "<table>" + s + "</table>"
        }
        return s
    }

    private enum Output { case node, text, html }

    private static func split(_ raw: String) -> (String, Output) {
        var p = strip(raw)
        for (suffix, out) in [("/html()", Output.html), ("/allText()", .text), ("/textNodes()", .text), ("/ownText()", .text)] {
            if p.hasSuffix(suffix) { p = String(p.dropLast(suffix.count)); return (p, out) }
        }
        // 相对路径 ./xxx 视为在整个片段内查找
        if p.hasPrefix("./") { p = "/" + p.dropFirst() }
        return (p, .node)
    }

    private static func query(_ obj: Any, _ path: String) -> XPathObject? {
        guard let doc = try? HTML(html: html(of: obj), encoding: .utf8) else { return nil }
        return doc.xpath(path)
    }

    /// 列表规则：返回每个匹配节点的 HTML（属性/文本节点返回文本）
    static func elements(_ obj: Any, _ rule: String) -> [Any] {
        let (path, _) = split(rule)
        guard let res = query(obj, path) else { return [] }
        switch res {
        case .String(let value): return value.isEmpty ? [] : [value]
        case .Number(let value): return [value]
        case .Bool(let value): return [value]
        case .NodeSet(let nodes):
            var out: [Any] = []
            for i in 0..<nodes.count {
                let n = nodes[i]
                if let h = n.toHTML, h.hasPrefix("<") { out.append(h) }
                else if let t = n.text { out.append(t) }
            }
            return out
        default: return []
        }
    }

    private static func fallbackString(_ obj: Any, _ path: String) -> String {
        guard let root = try? SwiftSoup.parse(html(of: obj)) else { return "" }
        var selector = path
        var attr: String?
        if let slash = selector.range(of: "/@", options: .backwards) {
            attr = String(selector[slash.upperBound...])
            selector = String(selector[..<slash.lowerBound])
        } else if selector.hasSuffix("/text()") {
            selector = String(selector.dropLast(7)); attr = "text"
        }
        selector = selector.replacingOccurrences(of: "//", with: " ")
            .replacingOccurrences(of: "/", with: " ")
        let classPattern = try? NSRegularExpression(pattern: "(div|ul|li|a|p)\\[@class=['\\\"]([^'\\\"]+)['\\\"]\\]")
        if let re = classPattern, let m = re.firstMatch(in: selector, range: NSRange(location: 0, length: (selector as NSString).length)) {
            let tag = (selector as NSString).substring(with: m.range(at: 1))
            let cls = (selector as NSString).substring(with: m.range(at: 2))
            selector = selector.replacingCharacters(in: Range(m.range, in: selector)!, with: "\(tag).\(cls.replacingOccurrences(of: " ", with: "."))")
        }
        if let re = try? NSRegularExpression(pattern: "\\[contains\\(text\\(\\),\\s*['\"]([^'\"]+)['\"]\\)\\]") {
            let ns = selector as NSString
            for m in re.matches(in: selector, range: NSRange(location: 0, length: ns.length)).reversed() {
                let text = ns.substring(with: m.range(at: 1))
                selector = (selector as NSString).replacingCharacters(in: m.range, with: ":contains(\(text))")
            }
        }
        selector = selector.trimmingCharacters(in: .whitespaces)
        let elements = (try? root.select(selector).array()) ?? []
        return elements.compactMap { e in
            if attr == "text" { return try? e.text() }
            if let attr { return try? e.attr(attr) }
            return try? e.text()
        }.joined(separator: "\n")
    }

    /// 文本规则：多个结果用换行连接
    static func string(_ obj: Any, _ rule: String) -> String {
        let (path, output) = split(rule)
        guard let res = query(obj, path) else { return fallbackString(obj, path) }
        switch res {
        case .none: return fallbackString(obj, path)
        case .String(let value): return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .Number(let value): return "\(value)"
        case .Bool(let value): return value ? "true" : "false"
        case .NodeSet(let nodes):
            var list: [String] = []
            for i in 0..<nodes.count {
                let n = nodes[i]
                let v: String? = output == .html ? n.innerHTML : n.text
                if let s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { list.append(s) }
            }
            return list.joined(separator: "\n")
        default: return ""
        }
    }
}
