import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var sources: [BookSource] = []
    @Published var books: [Book] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d
    }()
    private var sourcesFile: URL { dir.appendingPathComponent("bookSources.json") }
    private var booksFile: URL { dir.appendingPathComponent("bookshelf.json") }
    private var cacheDir: URL {
        let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chapters")
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        return c
    }

    init() { load() }

    func load() {
        if let d = try? Data(contentsOf: sourcesFile), let s = try? JSONDecoder().decode([BookSource].self, from: d) { sources = s }
        if let d = try? Data(contentsOf: booksFile), let b = try? JSONDecoder().decode([Book].self, from: d) { books = b }
    }

    func saveSources() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(sources) { try? d.write(to: sourcesFile, options: .atomic) }
    }

    func saveBooks() {
        if let d = try? JSONEncoder().encode(books) { try? d.write(to: booksFile, options: .atomic) }
    }

    func source(for url: String) -> BookSource? { sources.first { $0.bookSourceUrl == url } }

    // MARK: Import
    @discardableResult
    func importSources(json text: String) throws -> Int {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = t.data(using: .utf8) else { return 0 }
        var list: [BookSource] = []
        if t.hasPrefix("[") { list = try JSONDecoder().decode([BookSource].self, from: d) }
        else { list = [try JSONDecoder().decode(BookSource.self, from: d)] }
        list = list.filter { !$0.bookSourceUrl.isEmpty }
        for s in list {
            if let i = sources.firstIndex(where: { $0.bookSourceUrl == s.bookSourceUrl }) { sources[i] = s }
            else { sources.append(s) }
        }
        saveSources()
        return list.count
    }

    func importSources(from urlString: String) async throws -> Int {
        let au = AnalyzeUrl(rawUrl: urlString)
        let (body, _) = try await au.fetch()
        return try importSources(json: body)
    }

    func deleteSources(at offsets: IndexSet) { sources.remove(atOffsets: offsets); saveSources() }

    func toggleSource(_ s: BookSource) {
        guard let i = sources.firstIndex(of: s) else { return }
        sources[i].enabled = !(sources[i].enabled ?? true)
        saveSources()
    }

    // MARK: Bookshelf
    func isOnShelf(_ b: Book) -> Bool { books.contains { $0.bookUrl == b.bookUrl } }

    func addToShelf(_ b: Book) {
        if let i = books.firstIndex(where: { $0.bookUrl == b.bookUrl }) { books[i] = b } else { books.insert(b, at: 0) }
        saveBooks()
    }

    func removeFromShelf(_ b: Book) { books.removeAll { $0.bookUrl == b.bookUrl }; saveBooks() }

    func updateProgress(_ b: Book, index: Int, title: String?) {
        guard let i = books.firstIndex(where: { $0.bookUrl == b.bookUrl }) else { return }
        books[i].durChapterIndex = index
        books[i].durChapterTitle = title
        books[i].lastReadAt = Date()
        saveBooks()
    }

    // MARK: Chapter cache
    private func key(_ s: String) -> String { JavaBridge().md5Encode(s) }

    func cachedToc(_ b: Book) -> [BookChapter]? {
        let f = cacheDir.appendingPathComponent("toc_" + key(b.bookUrl) + ".json")
        guard let d = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode([BookChapter].self, from: d)
    }
    func saveToc(_ b: Book, _ c: [BookChapter]) {
        let f = cacheDir.appendingPathComponent("toc_" + key(b.bookUrl) + ".json")
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: f) }
    }
    func cachedContent(_ c: BookChapter) -> String? {
        try? String(contentsOf: cacheDir.appendingPathComponent("c_" + key(c.url) + ".txt"), encoding: .utf8)
    }
    func saveContent(_ c: BookChapter, _ text: String) {
        guard !text.isEmpty else { return }
        try? text.write(to: cacheDir.appendingPathComponent("c_" + key(c.url) + ".txt"), atomically: true, encoding: .utf8)
    }
}

final class ReadSettings: ObservableObject {
    @AppStorage("fontSize") var fontSize: Double = 19
    @AppStorage("lineSpacing") var lineSpacing: Double = 8
    @AppStorage("theme") var theme: Int = 0
    @AppStorage("pageMode") var pageMode: Int = 0 // 0 滚动 1 翻页

    static let themes: [(bg: Color, fg: Color, name: String)] = [
        (Color(red: 0.98, green: 0.96, blue: 0.90), Color(red: 0.2, green: 0.2, blue: 0.2), "米黄"),
        (Color.white, Color.black, "白色"),
        (Color(red: 0.80, green: 0.91, blue: 0.81), Color(red: 0.15, green: 0.25, blue: 0.15), "护眼"),
        (Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.65, green: 0.65, blue: 0.65), "夜间")
    ]
}
