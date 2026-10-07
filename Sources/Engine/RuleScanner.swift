import Foundation

/// Shared lexical boundaries for Legado rules, JSONPath and embedded templates.
/// A combination uses the first operator encountered, not a fixed precedence table.
enum RuleScanner {
    struct Split {
        let parts: [String]
        let separator: String?
        let valid: Bool
    }

    static func split(_ text: String, by operators: [String], firstOperatorOnly: Bool = true) -> Split {
        let result = scan(text, operators, firstOnly: false, firstOperatorOnly: firstOperatorOnly)
        guard result.valid else { return Split(parts: [text], separator: nil, valid: false) }
        var parts: [String] = []
        var start = text.startIndex
        for hit in result.hits {
            parts.append(String(text[start..<hit.0.lowerBound]))
            start = hit.0.upperBound
        }
        parts.append(String(text[start...]))
        return Split(parts: parts, separator: result.hits.first?.1, valid: true)
    }

    static func firstTopLevel(_ text: String, _ tokens: [String], caseInsensitive: Bool = false) -> Range<String.Index>? {
        scan(text, tokens, firstOnly: true, firstOperatorOnly: false, caseInsensitive: caseInsensitive).hits.first?.0
    }

    private static func scan(_ text: String, _ tokens: [String], firstOnly: Bool,
                             firstOperatorOnly: Bool, caseInsensitive: Bool = false)
        -> (hits: [(Range<String.Index>, String)], valid: Bool) {
        var hits: [(Range<String.Index>, String)] = []
        var stack: [Character] = []
        var quote: Character?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if stack.isEmpty, let token = tokens.first(where: { token in
                guard !token.isEmpty else { return false }
                if firstOperatorOnly, let chosen = hits.first?.1, token != chosen { return false }
                if caseInsensitive { return text[i...].prefix(token.count).lowercased() == token.lowercased() }
                return text[i...].hasPrefix(token)
            }) {
                let end = text.index(i, offsetBy: token.count)
                hits.append((i..<end, token))
                if firstOnly { return (hits, true) }
                i = end
                continue
            } else if let close = closing(c) {
                stack.append(close)
            } else if c == ")" || c == "]" || c == "}" {
                guard stack.last == c else { return (hits, false) }
                stack.removeLast()
            }
            i = text.index(after: i)
        }
        return (hits, stack.isEmpty && quote == nil)
    }

    private static func closing(_ c: Character) -> Character? {
        switch c {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        default: return nil
        }
    }

    static func balancedRange(_ text: String, at start: String.Index) -> Range<String.Index>? {
        guard start < text.endIndex, let endChar = closing(text[start]) else { return nil }
        var stack: [Character] = [endChar]
        var quote: Character?
        var i = text.index(after: start)
        while i < text.endIndex {
            let c = text[i]
            if c == "\\" {
                i = text.index(after: i)
                if i < text.endIndex { i = text.index(after: i) }
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" || c == "`" {
                quote = c
            } else if let close = closing(c) {
                stack.append(close)
            } else if c == ")" || c == "]" || c == "}" {
                guard stack.last == c else { return nil }
                stack.removeLast()
                if stack.isEmpty { return start..<text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Marker ends in '{' (or '{{'). Evaluate left to right, once per balanced group.
    static func replaceGroups(_ text: String, marker: String, caseInsensitive: Bool = false,
                              _ transform: (String) -> String) -> String {
        guard let brace = marker.firstIndex(of: "{") else { return text }
        let prefixCount = marker.distance(from: marker.startIndex, to: brace)
        let braceCount = marker.count - prefixCount
        var output = ""
        var start = text.startIndex
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while let match = text.range(of: marker, options: options, range: start..<text.endIndex) {
            let open = text.index(match.lowerBound, offsetBy: prefixCount)
            guard let group = balancedRange(text, at: open) else {
                output += String(text[start..<match.upperBound]); start = match.upperBound
                continue
            }
            let bodyEnd = text.index(group.upperBound, offsetBy: -braceCount)
            guard match.upperBound <= bodyEnd else { break }
            output += String(text[start..<match.lowerBound])
            output += transform(String(text[match.upperBound..<bodyEnd]))
            start = group.upperBound
        }
        return output + String(text[start...])
    }

    /// JSON quoting plus the single-quoted maps commonly used by book sources.
    static func unquote(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let q = t.first, (q == "\"" || q == "'"), t.count >= 2, t.last == q else { return nil }
        if q == "\"", let data = t.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return value
        }
        var result = ""
        var escaped = false
        for c in t.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"", "'", "/": result.append(c)
                default: result.append("\\"); result.append(c)
                }
                escaped = false
            } else if c == "\\" { escaped = true }
            else if c == q { return nil }
            else { result.append(c) }
        }
        return escaped ? nil : result
    }
}
