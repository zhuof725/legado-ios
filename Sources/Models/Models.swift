import Foundation

// MARK: - Legado-compatible BookSource JSON

struct SearchRule: Codable, Hashable {
    var checkKeyWord: String?
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?
}

struct BookInfoRule: Codable, Hashable {
    var `init`: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    var tocUrl: String?
    var wordCount: String?
}

struct TocRule: Codable, Hashable {
    var preUpdateJs: String?
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var isVolume: String?
    var isVip: String?
    var updateTime: String?
    var nextTocUrl: String?
}

struct ContentRule: Codable, Hashable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var imageStyle: String?
}

struct BookSource: Codable, Hashable, Identifiable {
    var id: String { bookSourceUrl }
    var bookSourceUrl: String
    var bookSourceName: String
    var bookSourceGroup: String?
    var bookSourceType: Int?
    var bookSourceComment: String?
    var enabled: Bool?
    var header: String?
    var jsLib: String?
    var searchUrl: String?
    var exploreUrl: String?
    var ruleSearch: SearchRule?
    var ruleExplore: SearchRule?
    var ruleBookInfo: BookInfoRule?
    var ruleToc: TocRule?
    var ruleContent: ContentRule?
    var customOrder: Int?
    var lastUpdateTime: Int64?

    var isEnabled: Bool { enabled ?? true }

    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookSourceComment
        case enabled, header, jsLib, searchUrl, exploreUrl
        case ruleSearch, ruleExplore, ruleBookInfo, ruleToc, ruleContent, customOrder, lastUpdateTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = (try? c.decode(String.self, forKey: .bookSourceUrl)) ?? ""
        bookSourceName = (try? c.decode(String.self, forKey: .bookSourceName)) ?? bookSourceUrl
        bookSourceGroup = try? c.decodeIfPresent(String.self, forKey: .bookSourceGroup)
        bookSourceType = try? c.decodeIfPresent(Int.self, forKey: .bookSourceType)
        bookSourceComment = try? c.decodeIfPresent(String.self, forKey: .bookSourceComment)
        enabled = try? c.decodeIfPresent(Bool.self, forKey: .enabled)
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        jsLib = try? c.decodeIfPresent(String.self, forKey: .jsLib)
        searchUrl = try? c.decodeIfPresent(String.self, forKey: .searchUrl)
        exploreUrl = try? c.decodeIfPresent(String.self, forKey: .exploreUrl)
        ruleSearch = BookSource.lenient(c, .ruleSearch)
        ruleExplore = BookSource.lenient(c, .ruleExplore)
        ruleBookInfo = BookSource.lenient(c, .ruleBookInfo)
        ruleToc = BookSource.lenient(c, .ruleToc)
        ruleContent = BookSource.lenient(c, .ruleContent)
        customOrder = try? c.decodeIfPresent(Int.self, forKey: .customOrder)
        lastUpdateTime = try? c.decodeIfPresent(Int64.self, forKey: .lastUpdateTime)
    }

    /// Some old sources store rule objects as JSON strings.
    private static func lenient<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> T? {
        if let v = try? c.decodeIfPresent(T.self, forKey: key) { return v }
        if let s = try? c.decodeIfPresent(String.self, forKey: key), let d = s.data(using: .utf8) {
            return try? JSONDecoder().decode(T.self, from: d)
        }
        return nil
    }
}

// MARK: - Book / Chapter

struct Book: Codable, Hashable, Identifiable {
    var id: String { bookUrl }
    var bookUrl: String
    var name: String
    var author: String = ""
    var intro: String?
    var kind: String?
    var coverUrl: String?
    var lastChapter: String?
    var wordCount: String?
    var tocUrl: String?
    var origin: String          // bookSourceUrl
    var originName: String = ""
    var durChapterIndex: Int = 0
    var durChapterPos: Int = 0
    var durChapterTitle: String?
    var addedAt: Date = Date()
    var lastReadAt: Date = Date()
}

struct BookChapter: Codable, Hashable, Identifiable {
    var id: String { url + "#\(index)" }
    var url: String
    var title: String
    var index: Int
    var isVolume: Bool = false
}
