import Foundation
import SwiftSoup

/// Legado-compatible rule analyzer: default JSoup syntax, @css:, @json:/$., @js:/<js>, ##regex, ||, &&, {{}}.
final class AnalyzeRule {
    let content: Any
    let baseUrl: String
    let jsLib: String?
    let context: RuleContext

    init(content: Any, baseUrl: String, jsLib: String? = nil, context: RuleContext = RuleContext()) {
        self.baseUrl = baseUrl
        self.jsLib = jsLib
        self.context = context
        if let s = content as? String {
            self.content = AnalyzeRule.parse(s, baseUrl: baseUrl)
        } else {
            self.content = content
        }
    }

    static func parse(_ s: String, baseUrl: String) -> Any {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("["), let d = t.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
            return o
        }
        if let doc = try? SwiftSoup.parse(s, baseUrl) { return doc }
        return s
    }

    // MARK: - JS splitting

    private func splitJS(_ rule: String) -> [(Bool, String)] {
        var parts: [(Bool, String)] = []
        var rest = rule
        while let r = rest.range(of: "<js>") {
            let before = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { parts.append((false, before)) }
            let after = rest[r.upperBound...]
            if let e = after.range(of: "</js>") {
                parts.append((true, String(after[..<e.lowerBound])))
                rest = String(after[e.upperBound...])
            } else {
                parts.append((true, String(after))); rest = ""
            }
        }
        if let r = rest.range(of: "@js:", options: .caseInsensitive) {
            let before = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { parts.append((false, before)) }
            parts.append((true, String(rest[r.upperBound...])))
        } else {
            let t = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append((false, t)) }
        }
        return parts
    }

    private func runJS(_ js: String, _ input: Any) -> Any {
        let expanded = expandEmbeddedTemplates(js, input: input)
        return JSEngine.shared.eval(expanded, result: AnalyzeRule.jsValue(input), baseUrl: baseUrl, jsLib: jsLib, rule: self, ruleInput: input, context: context) ?? ""
    }

    /// Legado 会在执行 @js:/<js> 前先展开其中的 {{规则}}。
    /// 例如 `{{$.bid}}` 必须从当前 JSON 节点取值，而不能直接交给 JSCore 解析。
    private func expandEmbeddedTemplates(_ script: String, input: Any) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{([\\s\\S]*?)\\}\\}") else { return script }
        var output = script
        let ns = script as NSString
        for match in re.matches(in: script, range: NSRange(location: 0, length: ns.length)).reversed() {
            let expression = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let value: String
            if expression == "baseUrl" { value = baseUrl }
            else if expression == "host" { value = context.get("host") }
            else if expression.hasPrefix("@get:") { value = context.get(String(expression.dropFirst(5))) }
            else if expression.hasPrefix("@") || expression.hasPrefix("$." ) || expression.hasPrefix("$[") || expression.hasPrefix("//") {
                value = singleString(input, expression.hasPrefix("@@") ? String(expression.dropFirst(2)) : expression)
            } else {
                value = AnalyzeRule.asString(JSEngine.shared.eval(expression, result: AnalyzeRule.jsValue(input), baseUrl: baseUrl, context: context) ?? "")
            }
            output = (output as NSString).replacingCharacters(in: match.range, with: value)
        }
        return output
    }

    static func jsValue(_ v: Any) -> Any {
        if let e = v as? Element { return (try? e.outerHtml()) ?? "" }
        if let a = v as? [Any] { return a.map { jsValue($0) } }
        return v
    }

    // MARK: - Public API

    func getString(_ rule: String?, from obj: Any? = nil) -> String {
        guard var rule = rule, !rule.isEmpty else { return "" }
        rule = resolvePut(rule, from: obj)
        if let g = obj as? [String], AnalyzeRule.hasGroupRef(rule) {
            rule = AnalyzeRule.fillGroups(rule, g)
            if !rule.contains("<js>") && rule.range(of: "@js:", options: .caseInsensitive) == nil {
                return rule.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var cur: Any = obj ?? content
        for (isJs, s) in splitJS(rule) {
            if isJs { cur = runJS(s, cur) }
            else {
                if let str = cur as? String, cur as AnyObject !== content as AnyObject { cur = AnalyzeRule.parse(str, baseUrl: baseUrl) }
                cur = stringValue(cur, s)
            }
        }
        return AnalyzeRule.asString(cur).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func getElements(_ rule: String?, from obj: Any? = nil) -> [Any] {
        guard let rule = rule, !rule.isEmpty else { return [] }
        var cur: Any = obj ?? content
        for (isJs, s) in splitJS(rule) {
            if isJs { cur = runJS(s, cur) }
            else {
                if let str = cur as? String { cur = AnalyzeRule.parse(str, baseUrl: baseUrl) }
                cur = elementsValue(cur, s)
            }
        }
        if let a = cur as? [Any] { return a }
        if let s = cur as? String {
            let p = AnalyzeRule.parse(s, baseUrl: baseUrl)
            if let a = p as? [Any] { return a }
            return [p]
        }
        return [cur]
    }

    private func resolvePut(_ raw: String, from obj: Any?) -> String {
        guard let re = try? NSRegularExpression(pattern: "@put:\\{([^{}]*)\\}") else { return raw }
        var out = raw
        let ns = raw as NSString
        for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)).reversed() {
            let body = ns.substring(with: m.range(at: 1))
            var values: [String: String] = [:]
            for pair in body.split(separator: ",") {
                let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
                let valueRule = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
                if !key.isEmpty { values[key] = singleString(obj ?? content, valueRule) }
            }
            context.putAll(values)
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        return out
    }

    // MARK: - String rules

    private func stringValue(_ obj: Any, _ rawRule: String) -> String {
        var rule = rawRule
        var regex: String? = nil, repl = "", firstOnly = false
        if let r = rule.range(of: "##") {
            let tail = String(rule[r.upperBound...])
            rule = String(rule[..<r.lowerBound])
            var segs = tail.components(separatedBy: "##")
            regex = segs.removeFirst()
            if !segs.isEmpty { repl = segs.removeFirst() }
            if tail.hasSuffix("###") { firstOnly = true }
        }
        var out: String
        if rule.contains("{{") {
            out = template(obj, rule)
        } else if rule.contains("||") {
            out = ""
            for r in rule.components(separatedBy: "||") {
                let v = singleString(obj, r); if !v.isEmpty { out = v; break }
            }
        } else if rule.contains("&&") {
            out = rule.components(separatedBy: "&&").map { singleString(obj, $0) }.filter { !$0.isEmpty }.joined(separator: "\n")
        } else if rule.contains("{$.") {
            out = replaceBraces(rule, pattern: "\\{(\\$\\.[^}]+)\\}") { self.singleString(obj, $0) }
        } else {
            if rule.isEmpty {
                if let e = obj as? Element { out = (try? e.outerHtml()) ?? "" } else { out = AnalyzeRule.asString(obj) }
            } else { out = singleString(obj, rule) }
        }
        if let re = regex, !re.isEmpty, let nre = try? NSRegularExpression(pattern: re) {
            let ns = out as NSString
            if firstOnly {
                if let m = nre.firstMatch(in: out, range: NSRange(location: 0, length: ns.length)) {
                    out = nre.replacementString(for: m, in: out, offset: 0, template: repl)
                } else { out = "" }
            } else {
                out = nre.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: ns.length), withTemplate: repl)
            }
        }
        return out
    }

    private func template(_ obj: Any, _ rule: String) -> String {
        replaceBraces(rule, pattern: "\\{\\{([\\s\\S]*?)\\}\\}") { inner in
            let t = inner.trimmingCharacters(in: .whitespaces)
            if t == "baseUrl" { return baseUrl }
            if t == "host" || t == "{{host}}" { return context.get("host") }
            if t.hasPrefix("@get:") { return context.get(String(t.dropFirst(5))) }
            if t.hasPrefix("@") || t.hasPrefix("$.") || t.hasPrefix("$[") || t.hasPrefix("//") {
                let rule = t.hasPrefix("@@") ? String(t.dropFirst(2)) : t
                return self.stringValue(obj, rule)
            }
            return AnalyzeRule.asString(self.runJS(t, obj))
        }
    }

    private func replaceBraces(_ s: String, pattern: String, _ f: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        let ns = s as NSString
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let v = f(ns.substring(with: m.range(at: 1)))
            result = (result as NSString).replacingCharacters(in: m.range, with: v)
        }
        return result
    }

    private func singleString(_ obj: Any, _ r: String) -> String {
        let rule = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.isEmpty { return "" }
        if isJsonRule(rule, obj) {
            return JsonPath.query(jsonRoot(obj), stripPrefix(rule)).map { AnalyzeRule.asString($0) }.joined(separator: "\n")
        }
        if XPathRule.isXPath(rule) { return XPathRule.string(obj, rule) }
        let isCss = rule.lowercased().hasPrefix("@css:")
        let body = isCss ? String(rule.dropFirst(5)) : rule
        guard let idx = body.range(of: "@", options: .backwards) else {
            // only attribute or only selector
            if let el = AnalyzeRule.element(obj) {
                if isCss { return elementsText((try? el.select(body).array()) ?? [], "text") }
                return elementsText([el], body)
            }
            return AnalyzeRule.asString(obj)
        }
        let sel = String(body[..<idx.lowerBound])
        let attr = String(body[idx.upperBound...])
        let els: [Element]
        if isCss { els = (try? AnalyzeRule.element(obj)?.select(sel).array()) ?? [] }
        else { els = defaultElements(obj, sel) }
        return elementsText(els, attr)
    }

    private func elementsText(_ els: [Element], _ attr: String) -> String {
        els.compactMap { e -> String? in
            switch attr {
            case "text": return try? e.text()
            case "ownText": return e.ownText()
            case "textNodes": return e.textNodes().map { $0.text() }.joined(separator: "\n")
            case "html":
                _ = try? e.select("script,style").remove()
                return try? e.html()
            case "all": return try? e.outerHtml()
            default: return try? e.attr(attr)
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Element rules

    private func elementsValue(_ obj: Any, _ r: String) -> [Any] {
        let rule = r.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.contains("||") {
            for x in rule.components(separatedBy: "||") { let v = elementsValue(obj, x); if !v.isEmpty { return v } }
            return []
        }
        if rule.contains("&&") { return rule.components(separatedBy: "&&").flatMap { elementsValue(obj, $0) } }
        if rule.contains("%%") { return AnalyzeRule.interleave(rule.components(separatedBy: "%%").map { elementsValue(obj, $0) }) }
        var main = rule, reverse = false
        if main.hasPrefix("-") { reverse = true; main.removeFirst() }
        if main.hasPrefix("+") { main.removeFirst() }
        var res: [Any]
        if main.hasPrefix(":") {
            res = AnalyzeRule.allInOne(obj, String(main.dropFirst()))
        } else if isJsonRule(main, obj) {
            res = JsonPath.query(jsonRoot(obj), stripPrefix(main)).flatMap { ($0 as? [Any]) ?? [$0] }
        } else if XPathRule.isXPath(main) {
            res = XPathRule.elements(obj, main)
        } else if main.lowercased().hasPrefix("@css:") {
            res = (try? AnalyzeRule.element(obj)?.select(String(main.dropFirst(5))).array()) ?? []
        } else {
            res = defaultElements(obj, main)
        }
        return reverse ? res.reversed() : res
    }

    private func defaultElements(_ obj: Any, _ rule: String) -> [Element] {
        guard let root = AnalyzeRule.element(obj) else { return [] }
        var cur: [Element] = [root]
        for seg in rule.components(separatedBy: "@") where !seg.isEmpty {
            cur = cur.flatMap { applySegment($0, seg) }
        }
        return cur
    }

    private func applySegment(_ el: Element, _ seg: String) -> [Element] {
        if let (base, spec) = AnalyzeRule.splitBracket(seg) {
            let l = (base.isEmpty || base == "children") ? el.children().array() : applySegment(el, base)
            return AnalyzeRule.pickIndexes(l, spec)
        }
        if seg.hasPrefix("."), seg.dropFirst().range(of: "^!?[-0-9:]+$", options: .regularExpression) != nil {
            return AnalyzeRule.pickIndexes(el.children().array(), String(seg.dropFirst()))
        }
        // 教程兼容：tag.dd!0:1:2 与 tag.dd.!0:1:2 都表示排除索引。
        var normalized = seg
        if let bang = normalized.firstIndex(of: "!") {
            let base = String(normalized[..<bang])
            if !base.hasSuffix(".") {
                normalized = base + "." + String(normalized[bang...])
            }
        }
        var parts = normalized.components(separatedBy: ".")
        let type = parts.removeFirst()
        var list: [Element]
        switch type {
        case "class": list = (try? el.getElementsByClass(parts.first ?? "").array()) ?? []
        case "tag": list = (try? el.getElementsByTag(parts.first ?? "").array()) ?? []
        case "id":
            if let found = ((try? el.getElementById(parts.first ?? "")) ?? nil) { list = [found] } else { list = [] }
        case "text": list = (try? el.getElementsContainingOwnText(parts.first ?? "").array()) ?? []
        case "children": list = el.children().array()
        default: return (try? el.select(seg).array()) ?? []
        }
        if type != "children" && !parts.isEmpty { parts.removeFirst() }
        guard let idxStr = parts.first, !idxStr.isEmpty else { return list }
        if idxStr.hasPrefix("!") {
            let ex = Set(idxStr.dropFirst().split(separator: ":").compactMap { Int($0) }.map { $0 < 0 ? list.count + $0 : $0 })
            return list.enumerated().filter { !ex.contains($0.offset) }.map { $0.element }
        }
        let idxs = idxStr.split(separator: ":").compactMap { Int($0) }
        return idxs.compactMap { i in
            let j = i < 0 ? list.count + i : i
            return (j >= 0 && j < list.count) ? list[j] : nil
        }
    }

    // MARK: - Helpers

    private func isJsonRule(_ rule: String, _ obj: Any) -> Bool {
        let l = rule.lowercased()
        if l.hasPrefix("@json:") || rule.hasPrefix("$.") || rule.hasPrefix("$[") { return true }
        if l.hasPrefix("@css:") || l.hasPrefix("@xpath:") { return false }
        return obj is [String: Any] || obj is [Any]
    }

    private func stripPrefix(_ r: String) -> String {
        r.lowercased().hasPrefix("@json:") ? String(r.dropFirst(6)) : r
    }

    private func jsonRoot(_ obj: Any) -> Any {
        if let s = obj as? String { return AnalyzeRule.parse(s, baseUrl: baseUrl) }
        if let e = obj as? Element, let t = try? e.text() { return AnalyzeRule.parse(t, baseUrl: baseUrl) }
        return obj
    }

    static func element(_ obj: Any) -> Element? {
        if let e = obj as? Element { return e }
        if let s = obj as? String { return try? SwiftSoup.parse(s) }
        return nil
    }

    static func asString(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case let e as Element: return (try? e.text()) ?? ""
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: return a.map { asString($0) }.joined(separator: "\n")
        case is NSNull: return ""
        default:
            if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
                return String(data: d, encoding: .utf8) ?? ""
            }
            return "\(v)"
        }
    }
}

/// Minimal JSONPath: $.a.b, $..a, [n], [-1], [*], ['k'], .*
enum JsonPath {
    static func query(_ root: Any, _ path: String) -> [Any] {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$") { p.removeFirst() }
        var cur: [Any] = [root]
        var i = p.startIndex
        while i < p.endIndex {
            if p[i...].hasPrefix("..") {
                i = p.index(i, offsetBy: 2)
                let key = readKey(p, &i)
                cur = cur.flatMap { deep($0, key) }
            } else if p[i] == "." {
                i = p.index(after: i)
                let key = readKey(p, &i)
                cur = cur.flatMap { child($0, key) }
            } else if p[i] == "[" {
                guard let end = p[i...].firstIndex(of: "]") else { break }
                let inner = String(p[p.index(after: i)..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
                i = p.index(after: end)
                cur = cur.flatMap { node -> [Any] in
                    if inner.hasPrefix("?") {
                        return filter(node, expression: String(inner.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
                    }
                    if inner == "*" { return child(node, "*") }
                    if let n = Int(inner), let a = node as? [Any] {
                        let j = n < 0 ? a.count + n : n
                        return (j >= 0 && j < a.count) ? [a[j]] : []
                    }
                    return child(node, inner)
                }
            } else {
                let key = readKey(p, &i)
                cur = cur.flatMap { child($0, key) }
            }
        }
        return cur
    }

    private static func filter(_ node: Any, expression: String) -> [Any] {
        let array: [Any]
        if let a = node as? [Any] { array = a }
        else if let d = node as? [String: Any] { array = Array(d.values) }
        else { return [] }
        let exp = expression.replacingOccurrences(of: "@.", with: "")
        let ops = ["==", "!=", " contains "]
        guard let op = ops.first(where: { exp.contains($0) }) else { return array }
        let parts = exp.components(separatedBy: op)
        guard parts.count == 2 else { return array }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = parts[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
        return array.filter { item in
            let actual: String
            if let d = item as? [String: Any] { actual = String(describing: d[key] ?? "") }
            else { actual = String(describing: item) }
            if op == "==" { return actual == expected }
            if op == "!=" { return actual != expected }
            return actual.localizedCaseInsensitiveContains(expected)
        }
    }

    private static func readKey(_ p: String, _ i: inout String.Index) -> String {
        let start = i
        while i < p.endIndex, p[i] != ".", p[i] != "[" { i = p.index(after: i) }
        return String(p[start..<i])
    }

    private static func child(_ node: Any, _ key: String) -> [Any] {
        if key == "*" {
            if let a = node as? [Any] { return a }
            if let d = node as? [String: Any] { return Array(d.values) }
            return []
        }
        if let d = node as? [String: Any], let v = d[key] { return [v] }
        if let a = node as? [Any] { return a.flatMap { child($0, key) } }
        return []
    }

    private static func deep(_ node: Any, _ key: String) -> [Any] {
        var out: [Any] = []
        if let d = node as? [String: Any] {
            if let v = d[key] { out.append(v) }
            for v in d.values { out += deep(v, key) }
        } else if let a = node as? [Any] {
            for v in a { out += deep(v, key) }
        }
        return out
    }
}
