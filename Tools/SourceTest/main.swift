import Foundation

// 云端书源测试：对每个书源依次执行 搜索 → 详情 → 目录 → 正文，并打印每一步的结果。
// 用法: SourceTest <sources.json> <关键词> [每个书源超时秒数]

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let path = args.count > 1 ? args[1] : "sources.json"
let key = args.count > 2 ? args[2] : "斗罗大陆"
let perSourceTimeout = Double(args.count > 3 ? args[3] : "60") ?? 60

guard let data = FileManager.default.contents(atPath: path) else { print("无法读取 \(path)"); exit(1) }
let sources: [BookSource]
do { sources = try JSONDecoder().decode([BookSource].self, from: data) }
catch { print("书源解析失败: \(error)"); exit(1) }
print("共 \(sources.count) 个书源，关键词：\(key)\n")

struct Timeout: Error {}

func withTimeout<T>(_ s: Double, _ op: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(s * 1e9)); throw Timeout() }
        let r = try await g.next()!
        g.cancelAll()
        return r
    }
}

func short(_ s: String?, _ n: Int = 80) -> String {
    let t = (s ?? "").replacingOccurrences(of: "\n", with: "⏎")
    return t.count > n ? String(t.prefix(n)) + "…" : t
}

var summary: [(String, String)] = []

for s in sources {
    print("==== \(s.bookSourceName)  \(s.bookSourceUrl)")
    print("  searchUrl: \(short(s.searchUrl, 120))")
    do {
        let result: String = try await withTimeout(perSourceTimeout) {
            let au = AnalyzeUrl(rawUrl: s.searchUrl ?? "", key: key, page: 1, baseUrl: s.bookSourceUrl, sourceHeader: s.header, context: RuleContext(source: s), jsLib: s.jsLib)
            print("  请求: \(au.method) \(short(au.url, 150))  charset=\(au.charset ?? "-") body=\(short(au.body, 80))")
            let (body, finalUrl) = try await au.fetch()
            print("  响应: \(body.count) 字符, url=\(short(finalUrl, 100)), 开头: \(short(body, 120))")
            try? FileManager.default.createDirectory(atPath: "dumps", withIntermediateDirectories: true)
            let safeName = s.bookSourceName.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            try? body.write(toFile: "dumps/\(safeName)-search.html", atomically: true, encoding: .utf8)
            let books = WebBook.parseBookList(source: s, body: body, baseUrl: finalUrl, rule: s.ruleSearch ?? SearchRule())
            print("  搜索结果: \(books.count) 条")
            guard let first = books.first(where: { $0.name.contains(key) }) ?? books.first else { return "搜索0条" }
            print("  第一本: \(first.name) / \(first.author) / \(short(first.bookUrl, 120))")
            let info = try await WebBook.bookInfo(source: s, book: first)
            print("  详情: tocUrl=\(short(info.tocUrl, 120)) intro=\(short(info.intro, 40))")
            let chapters = try await WebBook.chapters(source: s, book: info)
            print("  目录: \(chapters.count) 章, 第一章: \(short(chapters.first?.title)) \(short(chapters.first?.url, 120))")
            guard let c = chapters.first else { return "目录0章" }
            let text = try await WebBook.content(source: s, chapter: c, nextChapterUrl: chapters.count > 1 ? chapters[1].url : nil, book: info)
            print("  正文: \(text.count) 字符, 开头: \(short(text, 100))")
            return text.isEmpty ? "正文为空" : "OK(正文\(text.count)字)"
        }
        summary.append((s.bookSourceName, result))
    } catch is Timeout {
        print("  ✗ 超时")
        summary.append((s.bookSourceName, "超时"))
    } catch {
        print("  ✗ 出错: \(error)")
        summary.append((s.bookSourceName, "出错: \(error.localizedDescription)"))
    }
    print("")
}

print("======== 汇总 ========")
for (n, r) in summary { print("\(r.hasPrefix("OK") ? "✅" : "❌") \(n): \(r)") }
print("通过 \(summary.filter { $0.1.hasPrefix("OK") }.count)/\(summary.count)")
exit(0)
