import Foundation

/// 全书源搜索结果的合并与排序（对应 Legado SearchModel 的去重合并 + 按匹配度排序）。
/// 同一本书（书名+作者相同）合并为一条，记录来源数；排序：书名精确 > 书名前缀 > 书名包含 > 作者匹配 > 其他，
/// 同级按来源数多者靠前，再按先到先得。
struct SearchHit: Identifiable, Equatable {
    var book: Book
    /// 同一本书出现在多少个书源（含当前这条）。
    var sourceCount: Int
    var rank: Int
    var arrival: Int
    var id: String { book.id }
}

enum SearchRanking {
    /// 去掉空白与常见标点、转小写，用来比较书名/作者。
    static func normalize(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        let scalars = s.unicodeScalars.filter { !drop.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    /// 0 最相关。
    static func rank(name: String, author: String, key: String) -> Int {
        let k = normalize(key), n = normalize(name), a = normalize(author)
        if k.isEmpty { return 4 }
        if n == k { return 0 }
        if n.hasPrefix(k) { return 1 }
        if n.contains(k) { return 2 }
        if !a.isEmpty && (a == k || a.contains(k)) { return 3 }
        return 4
    }

    static func mergeKey(_ b: Book) -> String { normalize(b.name) + "\u{1}" + normalize(b.author) }

    /// 把一批新结果并入已有列表，返回新的有序列表。
    static func merge(existing: [SearchHit], new: [Book], key: String) -> [SearchHit] {
        var hits = existing
        var index: [String: Int] = [:]
        for (i, h) in hits.enumerated() { index[mergeKey(h.book)] = i }
        var arrival = (hits.map(\.arrival).max() ?? -1) + 1
        for b in new where !b.name.isEmpty {
            let k = mergeKey(b)
            if let i = index[k] {
                hits[i].sourceCount += 1
                // 保留信息更全的那条（有封面/简介优先）。
                if hits[i].book.coverUrl == nil, b.coverUrl != nil { hits[i].book.coverUrl = b.coverUrl }
                if hits[i].book.intro == nil, b.intro != nil { hits[i].book.intro = b.intro }
            } else {
                index[k] = hits.count
                hits.append(SearchHit(book: b, sourceCount: 1,
                                      rank: rank(name: b.name, author: b.author, key: key), arrival: arrival))
                arrival += 1
            }
        }
        return hits.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
            return $0.arrival < $1.arrival
        }
    }
}
