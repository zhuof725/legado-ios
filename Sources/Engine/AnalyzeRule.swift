import Foundation
import SwiftSoup

/// Legado-compatible rule analyzer: default JSoup syntax, @css:, @json:/$., @js:/<js>, ##regex, ||, &&, {{}}.
final class AnalyzeRule {
    let content: Any
    let baseUrl: String
    let jsLib: String?
    let context: RuleContext
    /// 原始响应文本。Legado 中顶层 JS 的 result 是原始字符串（如 data: URL 解出的十六进制），
    /// 不能是 SwiftSoup 重新序列化后的 <html> 文档。
    let rawContent: String?

    init(content: Any, baseUrl: String, jsLib: String? = nil, context: RuleContext = RuleContext()) {
        self.baseUrl = baseUrl
        self.jsLib = jsLib
        self.context = context
        if let s = content as? String {
            self.rawContent = s
            self.content = AnalyzeRule.parse(s, baseUrl: baseUrl)
        } else {
            self.rawContent = nil
            self.content = content
        }
    }

    /// 传给 JS 的 result：顶层文档用原始文本，其余节点按原逻辑转换
    private func jsInput(_ input: Any) -> Any {
        if let raw = rawContent, (input as AnyObject) === (content as AnyObject) { return raw }
        return AnalyzeRule.jsValue(input)
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
        // Match Kotlin AppPattern.JS_PATTERN; RuleScanner is not a JS lexer.
        guard let regex = try? NSRegularExpression(
            pattern: "<js>([\\s\\S]*?)</js>|@js:([\\s\\S]*)",
            options: [.caseInsensitive]
        ) else { return [(false, rule)] }
        let source = rule as NSString
        var parts: [(Bool, String)] = []
        var cursor = 0
        for match in regex.matches(in: rule, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > cursor {
                let before = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { parts.append((false, before)) }
            }
            let block = match.range(at: 1)
            let script = block.location != NSNotFound ? block : match.range(at: 2)
            parts.append((true, source.substring(with: script)))
            cursor = NSMaxRange(match.range)
        }
        if cursor < source.length {
            let tail = source.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { parts.append((false, tail)) }
        }
        return parts
    }

    private func resolvedHost() -> String {
        if let lib = jsLib, !lib.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let host = JSEngine.shared.evalString("typeof host === 'undefined' ? '' : String(host)", jsLib: lib, context: context), !host.isEmpty {
            return host
        }
        return context.get("host")
    }

    private func runJS(_ js: String, _ input: Any) -> Any {
        let expanded = expandEmbeddedTemplates(js, input: input)
        return JSEngine.shared.eval(expanded, result: jsInput(input), baseUrl: baseUrl, jsLib: jsLib, rule: self, ruleInput: input, context: context) ?? ""
    }

    /// Legado 会在执行 @js:/<js> 前先展开其中的 {{规则}}。
    /// 例如 `{{$.bid}}` 必须从当前 JSON 节点取值，而不能直接交给 JSCore 解析。
    private func expandEmbeddedTemplates(_ script: String, input: Any) -> String {
        RuleScanner.replaceGroups(script, marker: "{{") { inner in
            let expression = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if expression == "baseUrl" { return self.baseUrl }
            if expression == "host" { return self.resolvedHost() }
            if expression.lowercased().hasPrefix("@get:") {
                let key = String(expression.dropFirst(5))
                if key.hasPrefix("{"),
                   let group = RuleScanner.balancedRange(key, at: key.startIndex),
                   group.upperBound == key.endIndex {
                    return self.context.get(String(key.dropFirst().dropLast()))
                }
                return self.context.get(key)
            }
            if expression.hasPrefix("@") || expression.hasPrefix("$.") || expression.hasPrefix("$[") || expression.hasPrefix("//") {
                return self.stringValue(input, expression)
            }
            // Evaluate once directly; runJS would expand the same template again.
            return AnalyzeRule.asString(JSEngine.shared.eval(
                expression, result: AnalyzeRule.jsValue(input), baseUrl: self.baseUrl,
                jsLib: self.jsLib, rule: self, ruleInput: input, context: self.context
            ) ?? "")
        }
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
        guard let rawRule = rule, !rawRule.isEmpty else { return [] }
        let rule = resolvePut(rawRule, from: obj)
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
        RuleScanner.replaceGroups(raw, marker: "@put:{", caseInsensitive: true) { body in
            let pairs = RuleScanner.split(body, by: [","])
            guard pairs.valid else { return "@put:{" + body + "}" }
            var rules: [(String, String)] = []
            for pair in pairs.parts {
                guard let colon = RuleScanner.firstTopLevel(pair, [":"]) else {
                    return "@put:{" + body + "}"
                }
                let rawKey = String(pair[..<colon.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(pair[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = RuleScanner.unquote(rawKey) ?? rawKey
                let valueRule = RuleScanner.unquote(rawValue) ?? rawValue
                guard !key.isEmpty else { return "@put:{" + body + "}" }
                rules.append((key, valueRule))
            }
            var values: [String: String] = [:]
            for (key, valueRule) in rules {
                values[key] = self.stringValue(obj ?? self.content, valueRule)
            }
            self.context.putAll(values)
            return ""
        }
    }

    // MARK: - String rules

    private func topLevelRegexMarker(in s: String) -> Range<String.Index>? {
        RuleScanner.firstTopLevel(s, ["##"])
    }

    private func stringValue(_ obj: Any, _ rawRule: String) -> String {
        // 模板内部的 ##（如 {{$.docId##.*_}}）由 template() 单独处理；
        // 整条 URL/正文规则仍要保留原始模板分支，避免把 URL 当成 CSS 规则。
        var rule = rawRule
        var regex: String? = nil, repl = "", firstOnly = false
        if let r = topLevelRegexMarker(in: rule) {
            let tail = String(rule[r.upperBound...])
            rule = String(rule[..<r.lowerBound])
            var segs = tail.components(separatedBy: "##")
            regex = segs.removeFirst()
            if !segs.isEmpty { repl = segs.removeFirst() }
            if tail.hasSuffix("###") { firstOnly = true }
        }
        var out: String
        let combination = RuleScanner.split(rule, by: ["&&", "||", "%%"])
        if rule.contains("{{") {
            out = template(obj, rule)
        } else if rule.range(of: "@get:{", options: .caseInsensitive) != nil {
            // Kotlin treats @get substitutions as literal output, not a new selector.
            out = RuleScanner.replaceGroups(rule, marker: "@get:{", caseInsensitive: true) {
                self.context.get($0)
            }
        } else if !combination.valid {
            out = ""
        } else if combination.parts.count > 1 {
            let forceDefault = rule.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("@@")
            let parts = combination.parts.map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                return forceDefault && !trimmed.hasPrefix("@@") ? "@@" + trimmed : trimmed
            }
            switch combination.separator {
            case "||":
                out = ""
                for part in parts {
                    let value = stringValue(obj, part)
                    if !value.isEmpty { out = value; break }
                }
            case "%%":
                let lists: [[Any]] = parts.map { part in
                    self.stringValue(obj, part).split(separator: "\n").map { String($0) as Any }
                }
                out = AnalyzeRule.interleave(lists).map { AnalyzeRule.asString($0) }.joined(separator: "\n")
            default:
                out = parts.map { self.stringValue(obj, $0) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
            }
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
        RuleScanner.replaceGroups(rule, marker: "{{") { inner in
            let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "baseUrl" { return self.baseUrl }
            if t == "host" { return self.resolvedHost() }
            if t.lowercased().hasPrefix("@get:") {
                let key = String(t.dropFirst(5))
                if key.hasPrefix("{"),
                   let group = RuleScanner.balancedRange(key, at: key.startIndex),
                   group.upperBound == key.endIndex {
                    return self.context.get(String(key.dropFirst().dropLast()))
                }
                return self.context.get(key)
            }
            if t.hasPrefix("@") || t.hasPrefix("$.") || t.hasPrefix("$[") || t.hasPrefix("//") {
                return self.stringValue(obj, t)
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
        var rule = r.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceDefault = rule.hasPrefix("@@")
        if forceDefault { rule = String(rule.dropFirst(2)) }
        if rule.isEmpty { return "" }
        if !forceDefault, isJsonRule(rule, obj) {
            return JsonPath.query(jsonRoot(obj), stripPrefix(rule)).map { AnalyzeRule.asString($0) }.joined(separator: "\n")
        }
        if !forceDefault, XPathRule.isXPath(rule) { return XPathRule.string(obj, rule) }
        let isCss = rule.lowercased().hasPrefix("@css:")
        let body = isCss ? String(rule.dropFirst(5)) : rule
        let segments = RuleScanner.split(body, by: ["@"])
        guard segments.valid else { return "" }
        guard segments.parts.count > 1 else {
            // A bare default rule extracts an attribute; @css selects text.
            if let el = AnalyzeRule.element(obj) {
                if isCss { return elementsText((try? el.select(body).array()) ?? [], "text") }
                return elementsText([el], body)
            }
            return forceDefault ? "" : AnalyzeRule.asString(obj)
        }
        let sel = segments.parts.dropLast().joined(separator: "@")
        let attr = segments.parts.last ?? ""
        let els: [Element]
        if sel.isEmpty { els = AnalyzeRule.element(obj).map { [$0] } ?? [] }
        else if isCss { els = (try? AnalyzeRule.element(obj)?.select(sel).array()) ?? [] }
        else { els = defaultElements(obj, sel) }
        return elementsText(els, attr)
    }

    private func elementsText(_ els: [Element], _ attr: String) -> String {
        var seen = Set<String>()
        return els.compactMap { e -> String? in
            switch attr {
            case "text": return try? e.text()
            case "ownText": return e.ownText()
            case "textNodes": return e.textNodes().map { $0.text() }.joined(separator: "\n")
            case "html":
                _ = try? e.select("script,style").remove()
                return try? e.outerHtml()
            case "all": return try? e.outerHtml()
            default:
                guard let value = try? e.attr(attr),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(value).inserted else { return nil }
                return value
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Element rules

    private func elementsValue(_ obj: Any, _ r: String) -> [Any] {
        var rule = r.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceDefault = rule.hasPrefix("@@")
        if forceDefault { rule = String(rule.dropFirst(2)) }
        // AllInOne is a regex, not a list of selector combinations.
        if !forceDefault, rule.hasPrefix(":") {
            return AnalyzeRule.allInOne(obj, String(rule.dropFirst()))
        }
        let combination = RuleScanner.split(rule, by: ["&&", "||", "%%"])
        guard combination.valid else { return [] }
        if combination.parts.count > 1 {
            let parts = combination.parts.map { forceDefault ? "@@" + $0 : $0 }
            switch combination.separator {
            case "||":
                for part in parts {
                    let values = elementsValue(obj, part)
                    if !values.isEmpty { return values }
                }
                return []
            case "%%":
                return AnalyzeRule.interleave(parts.map { self.elementsValue(obj, $0) })
            default:
                return parts.flatMap { self.elementsValue(obj, $0) }
            }
        }
        var main = rule, reverse = false
        if main.hasPrefix("-") { reverse = true; main.removeFirst() }
        if main.hasPrefix("+") { main.removeFirst() }
        var res: [Any]
        if !forceDefault, main.hasPrefix(":") {
            res = AnalyzeRule.allInOne(obj, String(main.dropFirst()))
        } else if !forceDefault, isJsonRule(main, obj) {
            res = JsonPath.query(jsonRoot(obj), stripPrefix(main)).flatMap { ($0 as? [Any]) ?? [$0] }
        } else if !forceDefault, XPathRule.isXPath(main) {
            res = XPathRule.elements(obj, main)
        } else if main.lowercased().hasPrefix("@css:") {
            res = (try? AnalyzeRule.element(obj)?.select(String(main.dropFirst(5))).array()) ?? []
        } else {
            res = defaultElements(obj, main)
        }
        return reverse ? Array(res.reversed()) : res
    }

    private func defaultElements(_ obj: Any, _ rule: String) -> [Element] {
        let segments = RuleScanner.split(rule, by: ["@"])
        guard segments.valid, let root = AnalyzeRule.element(obj) else { return [] }
        var cur: [Element] = [root]
        for seg in segments.parts where !seg.isEmpty {
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
        default:
            // Legado 默认语法：非 class/tag/id/text/children 的段按 CSS 选择器处理，
            // 允许尾部带索引，如 .search@li!0、li.2、div.-1、li!0:1
            var css = seg
            var idxSpec: String? = nil
            if let bang = seg.lastIndex(of: "!") {
                css = String(seg[..<bang])
                idxSpec = String(seg[bang...])
            } else if let m = seg.range(of: "\\.(-?\\d+(:-?\\d+)*)$", options: .regularExpression) {
                css = String(seg[..<m.lowerBound])
                idxSpec = String(seg[seg.index(after: m.lowerBound)...])
            }
            if css.hasSuffix(".") { css.removeLast() }
            if css.isEmpty { return [] }
            let found = (try? el.select(css).array()) ?? []
            guard let spec = idxSpec, !spec.isEmpty else { return found }
            // 旧语法 !0:1:2 / 0:1 表示多个独立索引
            return AnalyzeRule.pickIndexes(found, spec.replacingOccurrences(of: ":", with: ","))
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
