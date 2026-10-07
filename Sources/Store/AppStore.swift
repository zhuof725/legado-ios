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

    // MARK: 本地书

    static let localOrigin = "local"
    private var localDir: URL {
        let d = dir.appendingPathComponent("LocalBooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func localFolder(_ b: Book) -> URL { localDir.appendingPathComponent(key(b.bookUrl), isDirectory: true) }

    func isLocal(_ b: Book) -> Bool { b.origin == AppStore.localOrigin }

    /// 导入 TXT / EPUB。成功返回加入书架的书；同一文件（内容一致）重复导入会覆盖同一本。
    @discardableResult
    func importLocalBook(url: URL) throws -> Book {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        let name = url.lastPathComponent
        let parsed: LocalBookData
        switch ext {
        case "txt", "text": parsed = try LocalBook.parseTXT(data, fileName: name)
        case "epub": parsed = try LocalBook.parseEPUB(data, fileName: name)
        default: throw LocalBookError.unsupported(ext)
        }
        let id = "local://" + JavaBridge().md5Encode(String(data.count) + parsed.title + (parsed.chapters.first?.text.prefix(200).description ?? ""))
        var book = Book(bookUrl: id, name: parsed.title, origin: AppStore.localOrigin)
        book.author = parsed.author
        book.originName = ext.uppercased() + " 本地"
        book.lastChapter = parsed.chapters.last?.title
        book.wordCount = String(parsed.chapters.reduce(0) { $0 + $1.text.count }) + " 字"
        let folder = localFolder(book)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var toc: [BookChapter] = []
        for (i, ch) in parsed.chapters.enumerated() {
            let u = "\(id)#\(i)"
            toc.append(BookChapter(url: u, title: ch.title, index: i))
            try ch.text.write(to: folder.appendingPathComponent("\(i).txt"), atomically: true, encoding: .utf8)
        }
        if let cover = parsed.coverData {
            let f = folder.appendingPathComponent("cover.img")
            try? cover.write(to: f)
            book.coverUrl = f.absoluteString
        }
        saveLocalToc(book, toc)
        if let old = books.first(where: { $0.bookUrl == book.bookUrl }) {
            book.durChapterIndex = old.durChapterIndex; book.durChapterPos = old.durChapterPos; book.durChapterTitle = old.durChapterTitle
        }
        addToShelf(book)
        return book
    }

    func localToc(_ b: Book) -> [BookChapter]? {
        guard let d = try? Data(contentsOf: localFolder(b).appendingPathComponent("toc.json")) else { return nil }
        return try? JSONDecoder().decode([BookChapter].self, from: d)
    }
    private func saveLocalToc(_ b: Book, _ toc: [BookChapter]) {
        if let d = try? JSONEncoder().encode(toc) { try? d.write(to: localFolder(b).appendingPathComponent("toc.json")) }
    }
    func localContent(_ b: Book, index: Int) -> String? {
        try? String(contentsOf: localFolder(b).appendingPathComponent("\(index).txt"), encoding: .utf8)
    }

    func deleteLocalFiles(_ b: Book) { try? FileManager.default.removeItem(at: localFolder(b)) }

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

    func removeFromShelf(_ b: Book) {
        if isLocal(b) { deleteLocalFiles(b) }
        books.removeAll { $0.bookUrl == b.bookUrl }; saveBooks()
    }

    func updateProgress(_ b: Book, index: Int, title: String?) {
        guard let i = books.firstIndex(where: { $0.bookUrl == b.bookUrl }) else { return }
        // 换章时章内位置归零；同一章内只更新时间。
        if books[i].durChapterIndex != index { books[i].durChapterPos = 0 }
        books[i].durChapterIndex = index
        books[i].durChapterTitle = title
        books[i].lastReadAt = Date()
        saveBooks()
    }

    /// 章内阅读位置：0...1000 的千分比（滚动偏移 / 可滚动总长）。用比例而不是像素，改字号后位置大致仍对。
    func updateScrollPosition(_ b: Book, permille: Int) {
        guard let i = books.firstIndex(where: { $0.bookUrl == b.bookUrl }) else { return }
        let v = min(max(permille, 0), 1000)
        guard books[i].durChapterPos != v else { return }
        books[i].durChapterPos = v
        books[i].lastReadAt = Date()
        saveBooksDebounced()
    }

    func scrollPosition(_ b: Book) -> Int {
        books.first(where: { $0.bookUrl == b.bookUrl })?.durChapterPos ?? b.durChapterPos
    }

    private var saveTask: Task<Void, Never>?
    /// 滚动时会频繁更新，合并写盘；进入后台或离开页面时调用 flushProgress 立即落盘。
    private func saveBooksDebounced() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            self?.saveBooks()
        }
    }

    func flushProgress() {
        saveTask?.cancel()
        saveTask = nil
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
    @AppStorage("pageTurnStyle") var pageTurnStyle: Int = 0 // 0 滑动 1 卷页 2 淡入淡出

    static let themes: [(bg: Color, fg: Color, name: String)] = [
        (Color(red: 0.98, green: 0.96, blue: 0.90), Color(red: 0.2, green: 0.2, blue: 0.2), "米黄"),
        (Color.white, Color.black, "白色"),
        (Color(red: 0.80, green: 0.91, blue: 0.81), Color(red: 0.15, green: 0.25, blue: 0.15), "护眼"),
        (Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.65, green: 0.65, blue: 0.65), "夜间")
    ]
}
