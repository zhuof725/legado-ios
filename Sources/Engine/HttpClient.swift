import Foundation

/// Parses Legado-style URLs: `https://x.com/search?q={{key}}&p={{page}},{"method":"POST","body":"k={{key}}","charset":"gbk","headers":{...}}`
struct AnalyzeUrl {
    var url: String
    var method: String = "GET"
    var body: String?
    var charset: String?
    var headers: [String: String] = [:]

    init(rawUrl: String, key: String? = nil, page: Int = 1, baseUrl: String? = nil, sourceHeader: String? = nil) {
        var s = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // @js: / <js></js> 先执行，再做模板替换（与 Legado 一致）
        s = AnalyzeUrl.evalUrlJS(s, key: key, page: page, baseUrl: baseUrl)
        s = AnalyzeUrl.substitute(s, key: key, page: page)
        // <1,2,3> page selection
        if let r = s.range(of: "<[^>]+>", options: .regularExpression) {
            let items = s[r].dropFirst().dropLast().split(separator: ",").map(String.init)
            let idx = min(max(page - 1, 0), max(items.count - 1, 0))
            s.replaceSubrange(r, with: items.isEmpty ? "" : items[idx])
        }
        // Split options JSON
        var options: [String: Any]? = nil
        if let r = s.range(of: ",\\s*\\{", options: .regularExpression) {
            let jsonPart = String(s[s.index(after: r.lowerBound)...]).trimmingCharacters(in: .whitespaces)
            if let o = AnalyzeUrl.looseJSON(jsonPart) {
                options = o
                s = String(s[..<r.lowerBound])
            }
        }
        url = AnalyzeUrl.absolute(s, base: baseUrl)
        if let h = sourceHeader, let o = AnalyzeUrl.looseJSON(h) {
            for (k, v) in o { headers[k] = "\(v)" }
        }
        if let o = options {
            if let m = o["method"] as? String { method = m.uppercased() }
            if let b = o["body"] { body = (b as? String) ?? AnalyzeUrl.jsonString(b) }
            if let c = o["charset"] as? String { charset = c }
            if let h = o["headers"] as? [String: Any] { for (k, v) in h { headers[k] = "\(v)" } }
        }
    }

    /// 解析 Legado 常见的单引号 JSON，如 {'method':'POST','body':'k=v'}
    static func looseJSON(_ s: String) -> [String: Any]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return nil }
        if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return o }
        guard let r = JSEngine.shared.eval("JSON.stringify(eval('(' + __src + ')'))", vars: ["__src": t]) as? String,
              let d = r.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// 执行 URL 规则里的 @js: 和 <js></js>，返回最终的 URL 字符串
    static func evalUrlJS(_ raw: String, key: String?, page: Int, baseUrl: String?) -> String {
        guard raw.contains("<js>") || raw.range(of: "@js:", options: .caseInsensitive) != nil else { return raw }
        var result = ""
        var rest = raw
        let vars: [String: Any] = ["key": key ?? "", "page": page, "searchKey": key ?? "", "searchPage": page]
        func run(_ js: String) {
            let v = JSEngine.shared.eval(js, result: result, baseUrl: baseUrl ?? "", vars: vars)
            result = v.map { AnalyzeRule.asString($0) } ?? ""
        }
        while let r = rest.range(of: "<js>") {
            let before = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { result = before }
            let after = rest[r.upperBound...]
            if let e = after.range(of: "</js>") {
                run(String(after[..<e.lowerBound])); rest = String(after[e.upperBound...])
            } else { run(String(after)); rest = "" }
        }
        if let r = rest.range(of: "@js:", options: .caseInsensitive) {
            let before = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { result = before }
            run(String(rest[r.upperBound...]))
        } else {
            let t = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result = t }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func substitute(_ s: String, key: String?, page: Int) -> String {
        var out = s
        let k = key ?? ""
        for (pat, val) in [("{{key}}", k), ("{key}", k), ("searchKey", k), ("{{page}}", "\(page)"), ("{page}", "\(page)"), ("searchPage", "\(page)")] {
            out = out.replacingOccurrences(of: pat, with: val)
        }
        // simple arithmetic like {{page-1}} / {{(page-1)*20}}
        let re = try! NSRegularExpression(pattern: "\\{\\{([^}]*)\\}\\}")
        let ns = out as NSString
        var result = out
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
            let expr = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "page", with: "\(page)")
                .replacingOccurrences(of: "key", with: "'\(k)'")
            let v = JSEngine.shared.evalString(expr) ?? ""
            result = (result as NSString).replacingCharacters(in: m.range, with: v)
        }
        return result
    }

    static func absolute(_ s: String, base: String?) -> String {
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("data:") { return s }
        guard let b = base, let bu = URL(string: b) else { return s }
        return URL(string: s, relativeTo: bu)?.absoluteString ?? s
    }

    static func jsonString(_ o: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func encoding(_ name: String?) -> String.Encoding {
        guard let n = name?.lowercased() else { return .utf8 }
        if n.contains("gb") {
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        if n.contains("big5") {
            let cf = CFStringEncoding(CFStringEncodings.big5.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
        return .utf8
    }

    func percentEncoded(_ s: String) -> String {
        let enc = AnalyzeUrl.encoding(charset)
        if enc == .utf8 {
            return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+"))) ?? s
        }
        guard let d = s.data(using: enc) else { return s }
        return d.map { b -> String in
            let c = Character(UnicodeScalar(b))
            if b < 0x80 && (c.isLetter || c.isNumber || "-_.~=&/:?".contains(c)) { return String(c) }
            return String(format: "%%%02X", b)
        }.joined()
    }

    func fetch() async throws -> (String, String) {
        let finalUrl = url.contains("%") ? url : percentEncoded(url)
        guard let u = URL(string: finalUrl) else { throw URLError(.badURL) }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body {
            req.httpBody = percentEncodedBody(b).data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                let isJson = b.trimmingCharacters(in: .whitespaces).hasPrefix("{")
                req.setValue(isJson ? "application/json" : "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        var enc = AnalyzeUrl.encoding(charset)
        if charset == nil, let n = (resp as? HTTPURLResponse)?.textEncodingName { enc = AnalyzeUrl.encoding(n) }
        var text = String(data: data, encoding: enc)
        if text == nil { text = String(data: data, encoding: AnalyzeUrl.encoding("gbk")) }
        if charset == nil, enc == .utf8, let t = text, t.range(of: "charset=[\"']?gb", options: [.regularExpression, .caseInsensitive]) != nil {
            text = String(data: data, encoding: AnalyzeUrl.encoding("gbk")) ?? t
        }
        return (text ?? "", resp.url?.absoluteString ?? url)
    }

    private func percentEncodedBody(_ b: String) -> String {
        if b.hasPrefix("{") || charset == nil { return b }
        return percentEncoded(b)
    }
}
