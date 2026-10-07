import Foundation

/// 对应 Legado BookList.analyzeBookList：
/// 1. bookUrlPattern 整串命中 -> 当前页按详情页解析，直接返回一条；
/// 2. 列表为空且没有 bookUrlPattern -> 同样按详情页解析；
/// 3. 列表为空但配置了 bookUrlPattern 且未命中 -> 返回空，不能误当详情页。
enum BookInfoFallbackRegression {
    static func run(_ check: (Bool, String) -> Void) {
        func source(pattern: String?) throws -> BookSource {
            var json: [String: Any] = [
                "bookSourceUrl": "https://info-fallback.invalid/" + UUID().uuidString,
                "bookSourceName": "Info fallback regression",
                "ruleSearch": ["bookList": "@css:.result-row", "name": "@css:.row-name@text", "bookUrl": "@css:a@href"],
                "ruleBookInfo": ["name": "@css:.bname@text", "author": "@css:.bauthor@text", "intro": "@css:.bintro@text"]
            ]
            if let pattern = pattern { json["bookUrlPattern"] = pattern }
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(BookSource.self, from: data)
        }
        let detailHTML = "<div><h1 class='bname'>凡人修仙传</h1><span class='bauthor'>忘语</span><p class='bintro'>一个普通山村小子</p></div>"
        let listHTML = "<div class='result-row'><span class='row-name'>斗罗大陆</span><a href='/b/1'>go</a></div>"
        do {
            let plain = try source(pattern: nil)
            let rule = plain.ruleSearch!

            let direct = WebBook.parseBookList(source: plain, body: detailHTML, baseUrl: "https://info-fallback.invalid/b/9", rule: rule)
            check(direct.count == 1 && direct[0].name == "凡人修仙传", "列表为空且无 bookUrlPattern：按详情页解析")
            check(direct.first?.author == "忘语", "详情回退取到作者")
            check(direct.first?.bookUrl == "https://info-fallback.invalid/b/9", "详情回退的 bookUrl 为当前页地址")

            let normal = WebBook.parseBookList(source: plain, body: listHTML, baseUrl: "https://info-fallback.invalid/s", rule: rule)
            check(normal.count == 1 && normal[0].name == "斗罗大陆", "列表非空时不走详情回退")

            let empty = WebBook.parseBookList(source: plain, body: "<html></html>", baseUrl: "https://info-fallback.invalid/s", rule: rule)
            check(empty.isEmpty, "空页面且详情也无书名：返回空")

            let withPattern = try source(pattern: "https://info-fallback\\.invalid/book/\\d+")
            let hit = WebBook.parseBookList(source: withPattern, body: detailHTML, baseUrl: "https://info-fallback.invalid/book/42", rule: withPattern.ruleSearch!)
            check(hit.count == 1 && hit[0].name == "凡人修仙传", "bookUrlPattern 命中：按详情页解析")

            // 即使页面含有列表，命中 bookUrlPattern 也优先按详情页处理。
            let hitList = WebBook.parseBookList(source: withPattern, body: listHTML + detailHTML, baseUrl: "https://info-fallback.invalid/book/42", rule: withPattern.ruleSearch!)
            check(hitList.count == 1 && hitList[0].name == "凡人修仙传", "bookUrlPattern 命中优先于列表")

            let miss = WebBook.parseBookList(source: withPattern, body: detailHTML, baseUrl: "https://info-fallback.invalid/search", rule: withPattern.ruleSearch!)
            check(miss.isEmpty, "配置了 bookUrlPattern 且未命中、列表为空：不回退详情页")

            // Kotlin 的 matches 要求整串匹配，前缀相同不算命中。
            let partial = WebBook.parseBookList(source: withPattern, body: detailHTML, baseUrl: "https://info-fallback.invalid/book/42/extra", rule: withPattern.ruleSearch!)
            check(partial.isEmpty, "bookUrlPattern 必须整串匹配")
            check(WebBook.matchesWholly("https://a/b/1", pattern: "https://a/b/\\d+"), "matchesWholly 命中")
            check(!WebBook.matchesWholly("https://a/b/1/x", pattern: "https://a/b/\\d+"), "matchesWholly 不接受前缀")
            check(!WebBook.matchesWholly("abc", pattern: "("), "非法正则视为不匹配")
        } catch {
            check(false, "BookInfoFallbackRegression 构造失败：\(error)")
        }
    }
}
