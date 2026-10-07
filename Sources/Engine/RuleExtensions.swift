import Foundation
import SwiftSoup

/// 按《Legado 书源规则：从入门到入土》补齐的规则语法
extension AnalyzeRule {

    // MARK: 正则之 AllInOne（以 : 开头，只用于列表规则）

    /// 返回每个匹配的分组数组 [$0, $1, $2 ...]
    static func allInOne(_ obj: Any, _ pattern: String) -> [Any] {
        let src: String
        if let e = obj as? Element { src = (try? e.outerHtml()) ?? "" }
        else if let s = obj as? String { src = s }
        else { src = asString(obj) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = src as NSString
        return re.matches(in: src, range: NSRange(location: 0, length: ns.length)).map { m -> [String] in
            (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func hasGroupRef(_ rule: String) -> Bool {
        rule.range(of: "\\$\\d", options: .regularExpression) != nil
    }

    /// 把规则中的 $1、$2 替换成 AllInOne 的分组
    static func fillGroups(_ rule: String, _ groups: [String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\$(\\d+)") else { return rule }
        var out = rule
        let ns = rule as NSString
        for m in re.matches(in: rule, range: NSRange(location: 0, length: ns.length)).reversed() {
            let i = Int(ns.substring(with: m.range(at: 1))) ?? 0
            out = (out as NSString).replacingCharacters(in: m.range, with: i < groups.count ? groups[i] : "")
        }
        return out
    }

    // MARK: 数组写法 [index,index] [start:end:step] [!index] [-1:0]

    static func pickIndexes<T>(_ list: [T], _ rawSpec: String) -> [T] {
        var spec = rawSpec.trimmingCharacters(in: .whitespaces)
        let n = list.count
        guard n > 0 else { return [] }
        let exclude = spec.hasPrefix("!")
        if exclude { spec.removeFirst() }
        func norm(_ i: Int) -> Int { i < 0 ? n + i : i }
        var idxs: [Int] = []
        for item in spec.split(separator: ",") {
            let t = item.trimmingCharacters(in: .whitespaces)
            if t.contains(":") {
                let p = t.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard (2...3).contains(p.count),
                      p.allSatisfy({ $0.isEmpty || Int($0) != nil }) else { return [] }
                var start = norm(Int(p[0]) ?? 0)
                var end = norm(Int(p[1]) ?? -1)
                let rawStep = p.count == 3 ? (Int(p[2]) ?? 1) : 1
                // Match Kotlin ElementsSingle: reject same-side out-of-range bounds,
                // then clamp endpoints before expanding an inclusive range.
                if (start < 0 && end < 0) || (start >= n && end >= n) { continue }
                start = min(n - 1, max(0, start))
                end = min(n - 1, max(0, end))
                if start == end || rawStep >= n {
                    idxs.append(start)
                    continue
                }
                // Negative CSS steps are relative to list length; avoid negating Int.min.
                let step = rawStep > 0 ? rawStep : (rawStep > -n ? rawStep + n : 1)
                let ascending = start <= end
                var index = start
                while true {
                    idxs.append(index)
                    let remaining = ascending ? end - index : index - end
                    if step > remaining { break }
                    index += ascending ? step : -step
                }
            } else if let i = Int(t) {
                idxs.append(norm(i))
            }
        }
        if exclude {
            let ex = Set(idxs)
            return list.enumerated().filter { !ex.contains($0.offset) }.map { $0.element }
        }
        var seen = Set<Int>()
        return idxs.compactMap { index in
            guard index >= 0, index < n, seen.insert(index).inserted else { return nil }
            return list[index]
        }
    }

    /// 拆出 "tag.a[-1:0]" → ("tag.a", "-1:0")
    static func splitBracket(_ seg: String) -> (String, String)? {
        guard seg.hasSuffix("]"), let l = seg.lastIndex(of: "[") else { return nil }
        let base = String(seg[..<l])
        let spec = String(seg[seg.index(after: l)..<seg.index(before: seg.endIndex)])
        if spec.range(of: "^!?[-0-9:, ]+$", options: .regularExpression) == nil { return nil }
        return (base, spec)
    }

    // MARK: %% 依次交错取值

    static func interleave(_ lists: [[Any]]) -> [Any] {
        var out: [Any] = []
        let maxLen = lists.map { $0.count }.max() ?? 0
        for i in 0..<maxLen { for l in lists where i < l.count { out.append(l[i]) } }
        return out
    }
}
