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
                let start = norm(Int(p[0]) ?? 0)
                let end = norm(p.count > 1 ? (Int(p[1]) ?? -1) : -1)
                let step = max(abs(p.count > 2 ? (Int(p[2]) ?? 1) : 1), 1)
                if start <= end { idxs += Array(stride(from: start, through: end, by: step)) }
                else { idxs += Array(stride(from: start, through: end, by: -step)) }
            } else if let i = Int(t) {
                idxs.append(norm(i))
            }
        }
        if exclude {
            let ex = Set(idxs)
            return list.enumerated().filter { !ex.contains($0.offset) }.map { $0.element }
        }
        return idxs.compactMap { ($0 >= 0 && $0 < n) ? list[$0] : nil }
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
