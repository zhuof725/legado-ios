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
        var out: [Any] = []
        for n in res {
            if let h = n.toHTML, h.hasPrefix("<") { out.append(h) }
            else if let t = n.text { out.append(t) }
        }
        return out
    }

    /// 文本规则：多个结果用换行连接
    static func string(_ obj: Any, _ rule: String) -> String {
        let (path, output) = split(rule)
        guard let res = query(obj, path) else { return "" }
        var list: [String] = []
        for n in res {
            let v: String? = output == .html ? n.innerHTML : n.text
            if let s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { list.append(s) }
        }
        return list.joined(separator: "\n")
    }
}
