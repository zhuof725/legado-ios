import Foundation
import CoreFoundation

/// The commonly used Jayway JSONPath subset. Invalid syntax fails closed.
enum JsonPath {
    private indirect enum Step {
        case key(String), keys([String]), indexes([Int]), wildcard
        case slice(Int?, Int?, Int), recursive(Step), filter(Predicate), length
    }
    private enum Operand {
        case path([Step], Bool), literal(Any)
    }
    private indirect enum Predicate {
        case and([Predicate]), or([Predicate]), not(Predicate)
        case compare(Operand, String, Operand), exists(Operand)
    }

    static func query(_ root: Any, _ path: String) -> [Any] {
        guard let steps = parse(path, depth: 0) else { return [] }
        return evaluate([root], steps, root: root)
    }

    static func isSimpleKeyRule(_ rule: String) -> Bool {
        let t = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasPrefix("@"), !t.hasPrefix("/"), !t.hasPrefix(".") else { return false }
        return parse(t, depth: 0) != nil
    }

    private static func parse(_ raw: String, depth: Int) -> [Step]? {
        guard depth < 64 else { return nil }
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return nil }
        var i = p.startIndex
        var steps: [Step] = []
        if p[i] == "$" {
            i = p.index(after: i)
            if i < p.endIndex, p[i] != ".", p[i] != "[" { return nil }
        }
        while i < p.endIndex {
            let before = i
            var recursive = false
            if p[i] == "." {
                i = p.index(after: i)
                if i < p.endIndex, p[i] == "." { recursive = true; i = p.index(after: i) }
                guard i < p.endIndex else { return nil }
            } else if !steps.isEmpty, p[i] != "[" { return nil }
            let step: Step
            if p[i] == "[" {
                guard let group = RuleScanner.balancedRange(p, at: i) else { return nil }
                let body = String(p[p.index(after: i)..<p.index(before: group.upperBound)])
                guard let parsed = bracket(body, depth: depth + 1) else { return nil }
                step = parsed; i = group.upperBound
            } else {
                let start = i
                while i < p.endIndex, p[i] != ".", p[i] != "[" { i = p.index(after: i) }
                let key = String(p[start..<i])
                if key == "*" { step = .wildcard }
                else if key == "length()" || key == "size()" { step = .length }
                else {
                    guard key.range(of: "^[\\p{L}\\p{N}_$-]+$", options: .regularExpression) != nil else { return nil }
                    step = .key(key)
                }
            }
            steps.append(recursive ? .recursive(step) : step)
            guard i > before else { return nil }
        }
        return steps
    }

    private static func bracket(_ raw: String, depth: Int) -> Step? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if body == "*" { return .wildcard }
        if body.hasPrefix("?") {
            let expression = String(body.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard expression.hasPrefix("("), let group = RuleScanner.balancedRange(expression, at: expression.startIndex),
                  group.upperBound == expression.endIndex, let predicate = predicate(expression, depth: depth + 1) else { return nil }
            return .filter(predicate)
        }
        let union = RuleScanner.split(body, by: [","])
        guard union.valid else { return nil }
        if union.parts.count > 1 {
            let keys = union.parts.compactMap { RuleScanner.unquote($0) }
            if keys.count == union.parts.count { return .keys(keys) }
            let indexes = union.parts.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return indexes.count == union.parts.count ? .indexes(indexes) : nil
        }
        if let key = RuleScanner.unquote(body) { return .key(key) }
        if let index = Int(body) { return .indexes([index]) }
        let slice = RuleScanner.split(body, by: [":"])
        guard slice.valid, (2...3).contains(slice.parts.count) else { return nil }
        let fields = slice.parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.allSatisfy({ $0.isEmpty || Int($0) != nil }) else { return nil }
        let step = fields.count == 3 ? (Int(fields[2]) ?? 1) : 1
        guard step != 0 else { return nil }
        return .slice(Int(fields[0]), Int(fields[1]), step)
    }

    private static func evaluate(_ nodes: [Any], _ steps: [Step], root: Any) -> [Any] {
        var current = nodes
        for step in steps { current = current.flatMap { apply($0, step, root: root) } }
        return current
    }

    private static func children(_ node: Any) -> [Any] {
        if let a = node as? [Any] { return a }
        if let d = node as? [String: Any] { return d.keys.sorted().compactMap { d[$0] } }
        return []
    }

    private static func apply(_ node: Any, _ step: Step, root: Any) -> [Any] {
        switch step {
        case .key(let key):
            if let d = node as? [String: Any], let value = d[key] { return [value] }
            if let a = node as? [Any] { return a.flatMap { apply($0, step, root: root) } }
            return []
        case .keys(let keys):
            guard let d = node as? [String: Any] else { return [] }
            return keys.compactMap { d[$0] }
        case .indexes(let indexes):
            guard let a = node as? [Any] else { return [] }
            return indexes.compactMap { index in
                let n = index < 0 ? a.count + index : index
                return n >= 0 && n < a.count ? a[n] : nil
            }
        case .wildcard: return children(node)
        case .slice(let start, let end, let step):
            guard let a = node as? [Any], !a.isEmpty else { return [] }
            let n = a.count
            func bound(_ value: Int, _ low: Int, _ high: Int) -> Int {
                let normalized = value < 0 ? n + value : value
                return min(high, max(low, normalized))
            }
            var i = start.map { bound($0, step > 0 ? 0 : -1, step > 0 ? n : n - 1) } ?? (step > 0 ? 0 : n - 1)
            let stop = end.map { bound($0, step > 0 ? 0 : -1, step > 0 ? n : n - 1) } ?? (step > 0 ? n : -1)
            var out: [Any] = []
            while step > 0 ? i < stop : i > stop {
                out.append(a[i])
                let next = i.addingReportingOverflow(step)
                if next.overflow { break }
                i = next.partialValue
            }
            return out
        case .recursive(let selector):
            // Iterative traversal avoids recursion on deeply nested documents.
            var pending: [Any] = [node]
            var out: [Any] = []
            while let next = pending.popLast() {
                if case .key(let key) = selector {
                    if let d = next as? [String: Any], let value = d[key] { out.append(value) }
                } else { out += apply(next, selector, root: root) }
                pending.append(contentsOf: children(next).reversed())
            }
            return out
        case .filter(let test): return children(node).filter { matches(test, current: $0, root: root) }
        case .length:
            if let a = node as? [Any] { return [a.count] }
            if let s = node as? String { return [s.count] }
            if let d = node as? [String: Any] { return [d.count] }
            return []
        }
    }

    private static func predicate(_ raw: String, depth: Int) -> Predicate? {
        guard depth < 64 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "(",
           let group = RuleScanner.balancedRange(text, at: text.startIndex),
           group.upperBound == text.endIndex {
            return predicate(String(text.dropFirst().dropLast()), depth: depth + 1)
        }
        // Predicate precedence is JSONPath precedence, not rule-combination order.
        for op in ["||", "&&"] {
            let split = RuleScanner.split(text, by: [op])
            guard split.valid else { return nil }
            if split.parts.count > 1 {
                let tests = split.parts.compactMap { predicate($0, depth: depth + 1) }
                guard tests.count == split.parts.count else { return nil }
                return op == "||" ? .or(tests) : .and(tests)
            }
        }
        if text.hasPrefix("!"), !text.hasPrefix("!=") {
            guard let test = predicate(String(text.dropFirst()), depth: depth + 1) else { return nil }
            return .not(test)
        }
        let operators = ["==", "!=", ">=", "<=", ">", "<", " contains ", " in ", " nin "]
        if let range = RuleScanner.firstTopLevel(text, operators) {
            guard let left = operand(String(text[..<range.lowerBound]), depth: depth + 1),
                  let right = operand(String(text[range.upperBound...]), depth: depth + 1) else { return nil }
            return .compare(left, String(text[range]).trimmingCharacters(in: .whitespaces), right)
        }
        // Unsupported operators/functions must never degrade into match-all.
        guard let value = operand(text, depth: depth + 1), case .path = value else { return nil }
        return .exists(value)
    }

    private static func operand(_ raw: String, depth: Int) -> Operand? {
        guard depth < 64 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.first == "@" || text.first == "$" {
            let isRoot = text.first == "$"
            let path = isRoot ? text : "$" + String(text.dropFirst())
            guard let steps = parse(path, depth: depth + 1) else { return nil }
            return .path(steps, isRoot)
        }
        if let string = RuleScanner.unquote(text) { return .literal(string) }
        if text == "true" { return .literal(NSNumber(value: true)) }
        if text == "false" { return .literal(NSNumber(value: false)) }
        if text == "null" { return .literal(NSNull()) }
        if text.first == "[" {
            guard let group = RuleScanner.balancedRange(text, at: text.startIndex),
                  group.upperBound == text.endIndex else { return nil }
            let body = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { return .literal([Any]()) }
            let split = RuleScanner.split(body, by: [","])
            guard split.valid else { return nil }
            var values: [Any] = []
            for part in split.parts {
                guard let item = operand(part, depth: depth + 1), case .literal(let value) = item else { return nil }
                values.append(value)
            }
            return .literal(values)
        }
        if text.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
           let number = Double(text), number.isFinite {
            return .literal(NSNumber(value: number))
        }
        return nil
    }

    private static func values(_ operand: Operand, current: Any, root: Any) -> [Any] {
        switch operand {
        case .literal(let value): return [value]
        case .path(let steps, let isRoot): return evaluate([isRoot ? root : current], steps, root: root)
        }
    }

    private static func matches(_ test: Predicate, current: Any, root: Any) -> Bool {
        switch test {
        case .and(let tests): return tests.allSatisfy { matches($0, current: current, root: root) }
        case .or(let tests): return tests.contains { matches($0, current: current, root: root) }
        case .not(let test): return !matches(test, current: current, root: root)
        case .exists(let operand): return !values(operand, current: current, root: root).isEmpty
        case .compare(let lhs, let op, let rhs):
            let left = values(lhs, current: current, root: root)
            let right = values(rhs, current: current, root: root)
            guard !left.isEmpty, !right.isEmpty else { return false }
            return left.contains { a in right.contains { b in compare(a, op, b) } }
        }
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull || b is NSNull { return a is NSNull && b is NSNull }
        if let x = a as? NSNumber, let y = b as? NSNumber {
            let xBool = CFGetTypeID(x) == CFBooleanGetTypeID()
            let yBool = CFGetTypeID(y) == CFBooleanGetTypeID()
            return xBool == yBool && x.compare(y) == .orderedSame
        }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? [Any], let y = b as? [Any] {
            return x.count == y.count && zip(x, y).allSatisfy { equal($0.0, $0.1) }
        }
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            return x.count == y.count && x.allSatisfy { pair in
                guard let value = y[pair.key] else { return false }
                return equal(pair.value, value)
            }
        }
        return false
    }

    private static func compare(_ a: Any, _ op: String, _ b: Any) -> Bool {
        switch op {
        case "==": return equal(a, b)
        case "!=": return !equal(a, b)
        case "contains":
            if let list = a as? [Any] { return list.contains { equal($0, b) } }
            if let text = a as? String, let part = b as? String { return text.contains(part) }
            return false
        case "in", "nin":
            guard let list = b as? [Any] else { return false }
            let found = list.contains { equal(a, $0) }
            return op == "in" ? found : !found
        default: break
        }
        let order: ComparisonResult
        if let x = a as? NSNumber, let y = b as? NSNumber,
           CFGetTypeID(x) != CFBooleanGetTypeID(), CFGetTypeID(y) != CFBooleanGetTypeID() {
            order = x.compare(y)
        } else if let x = a as? String, let y = b as? String {
            order = x.compare(y, options: .literal)
        } else { return false }
        switch op {
        case ">": return order == .orderedDescending
        case "<": return order == .orderedAscending
        case ">=": return order != .orderedAscending
        case "<=": return order != .orderedDescending
        default: return false
        }
    }
}
