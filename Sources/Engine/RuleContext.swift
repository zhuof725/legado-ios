import Foundation

/// 一次 Legado 规则执行的上下文。
/// Android 原版通过 Rhino scope 保存 source/book/chapter；iOS 不能使用全局变量，
/// 因此每个搜索、详情、目录、正文请求都创建自己的上下文。
final class RuleContext {
    var source: BookSource?
    var book: Book?
    var chapter: BookChapter?
    private var variables: [String: String] = [:]

    init(source: BookSource? = nil, book: Book? = nil, chapter: BookChapter? = nil) {
        self.source = source
        self.book = book
        self.chapter = chapter
        if let raw = source?.bookSourceUrl {
            variables["host"] = raw.components(separatedBy: "#").first ?? raw
            variables["baseUrl"] = raw
        }
    }

    func put(_ key: String, _ value: String) -> String {
        variables[key] = value
        return value
    }

    func get(_ key: String) -> String { variables[key] ?? "" }

    func putAll(_ values: [String: String]) {
        for (key, value) in values { variables[key] = value }
    }
}
