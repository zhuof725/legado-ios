import Foundation

/// Offline fixtures; the shared runner registers run explicitly.
/// Requires a Swift host with the application's normal parser/JS dependencies.
enum BookContextRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let base = "https://book-context.invalid/" + UUID().uuidString
        func source(_ suffix: String) throws -> BookSource {
            let data = try JSONSerialization.data(withJSONObject: [
                "bookSourceUrl": base + "#" + suffix,
                "bookSourceName": "Book context regression"
            ])
            return try JSONDecoder().decode(BookSource.self, from: data)
        }
        do {
            for isJSON in [true, false] {
                let label = isJSON ? "JSON" : "HTML"
                let src = try source(label)
                let list = RuleContext(source: src)
                _ = list.put("requestToken", "request")
                let body = isJSON
                    ? #"{"items":[{"bid":"a","name":"Alpha"},{"bid":"b","name":"Beta"}]}"#
                    : "<main><article data-bid='a'><h2>Alpha</h2></article><article data-bid='b'><h2>Beta</h2></article></main>"
                let bidRule = isJSON ? "$.bid" : "@css:article@data-bid"
                let nameRule = isJSON ? "$.name" : "@css:h2@text"
                var rule = SearchRule()
                rule.bookList = isJSON
                    ? "@js:java.put('listToken','list'); JSON.parse(result).items"
                    : "@js:java.put('listToken','list'); java.getElements('@css:article')"
                rule.name = """
                    @js:java.put('bid', java.getString('\(bidRule)'));
                    java.put('inherited', java.get('requestToken') + '/' + java.get('listToken'));
                    java.put('order', 'name'); java.getString('\(nameRule)');
                    """
                rule.author = "@js:java.put('order',java.get('order')+',author'); book.name + '-author'"
                rule.kind = "@js:java.put('order',java.get('order')+',kind'); book.author + '-kind'"
                rule.wordCount = "@js:java.put('order',java.get('order')+',wordCount'); java.put('priorKind',book.kind); '100'"
                rule.lastChapter = "@js:java.put('order',java.get('order')+',lastChapter'); 'Latest'"
                rule.intro = "@js:java.put('order',java.get('order')+',intro'); book.kind + '-intro'"
                rule.coverUrl = "@js:java.put('order',java.get('order')+',coverUrl'); java.put('priorIntro',book.intro); '/cover/' + java.get('bid')"
                rule.bookUrl = """
                    @js:java.put('order',java.get('order')+',bookUrl');
                    java.put('urlFields', book.name + '|' + book.author + '|' + book.kind + '|' + book.intro);
                    '/book/' + java.get('bid') + '/' + java.get('priorKind');
                    """
                let books = WebBook.parseBookList(source: src, body: body, baseUrl: base + "/search", rule: rule, context: list)
                check(books.count == 2, label + ": two independent results")
                guard books.count == 2 else { continue }
                _ = list.put("listToken", "changed-after-list")
                for (index, book) in books.enumerated() {
                    let bid = index == 0 ? "a" : "b"
                    let name = index == 0 ? "Alpha" : "Beta"
                    let detail = RuleContext(source: src, book: book)
                    check(book.name == name && book.author == name + "-author" && book.kind == name + "-author-kind", label + ": later fields see updated book properties")
                    check(book.wordCount == "100" && book.lastChapter == "Latest" && book.coverUrl == "https://book-context.invalid/cover/" + bid, label + ": remaining fields are retained")
                    check(book.bookUrl == "https://book-context.invalid/book/" + bid + "/" + name + "-author-kind", label + ": final URL reads earlier item variables")
                    check(detail.get("bid") == bid, label + ": fresh detail context retains its own bid")
                    check(detail.get("inherited") == "request/list" && detail.get("listToken") == "list", label + ": both books retain the list-stage snapshot")
                    check(detail.get("order") == "name,author,kind,wordCount,lastChapter,intro,coverUrl,bookUrl", label + ": Kotlin field execution order")
                    check(detail.get("urlFields") == [name, name + "-author", name + "-author-kind", name + "-author-kind-intro"].joined(separator: "|"), label + ": URL sees updated name author kind intro")
                    check(detail.get("priorIntro") == book.intro, label + ": cover rule sees parsed intro")
                }
                check(list.get("bid").isEmpty && list.get("order").isEmpty && list.get("urlFields").isEmpty, label + ": item writes never pollute source")
                let otherSource = try source(label + "-other")
                let other = RuleContext(source: otherSource, book: books[0])
                check(other.get("bid").isEmpty, label + ": same URL is isolated by full source ID")
                _ = other.put("bid", "other-source")
                check(RuleContext(source: src, book: books[0]).get("bid") == "a", label + ": source fragment suffix remains part of identity")

                var emptyRule = rule
                emptyRule.bookList = isJSON ? "$.missing[*]" : "@css:.missing"
                check(WebBook.parseBookList(source: src, body: body, baseUrl: base, rule: emptyRule, context: list).isEmpty, label + ": no results create no books")
                var unnamedRule = rule
                unnamedRule.name = "@js:java.put('discarded','unnamed'); ''"
                check(WebBook.parseBookList(source: src, body: body, baseUrl: base, rule: unnamedRule, context: list).isEmpty, label + ": unnamed items are discarded")
                check(list.get("discarded").isEmpty && RuleContext(source: src, book: books[0]).get("discarded").isEmpty, label + ": discarded items do not reach source or final books")
            }

            let src = try source("direct")
            let list = RuleContext(source: src)
            _ = list.put("fallback", "snapshot")
            var book = Book(bookUrl: "", name: "Pending", origin: src.bookSourceUrl)
            var pending: RuleContext? = list.forkForBook(book)
            weak var released = pending
            _ = pending?.put("bid", "pending")
            _ = pending?.put("fallback", "")
            pending?.bindBook(book)
            check(pending?.get("bid") == "pending" && list.get("bid").isEmpty,
                  "empty final URL keeps variables pending without publishing to source")
            book.bookUrl = base + "/provisional"
            pending?.book = book
            _ = pending?.put("afterProvisional", "private")
            check(RuleContext(source: src, book: book).get("afterProvisional").isEmpty && list.get("bid").isEmpty, "updating bookUrl alone cannot publish pending variables")
            _ = list.put("fallback", "changed")
            check(pending?.get("fallback") == "snapshot", "pending empty value falls back to frozen list snapshot")
            book.bookUrl = base + "/final"
            pending?.bindBook(book)
            let detail = RuleContext(source: src, book: book)
            check(detail.get("bid") == "pending" && detail.get("afterProvisional") == "private" && detail.get("fallback") == "snapshot", "binding publishes variables only to final identity")
            _ = detail.put("bid", "fresh")
            check(pending?.get("bid") == "fresh", "bound context resumes normal shared lookup without stale cache")
            pending = nil
            check(released == nil, "shared stores do not retain temporary contexts")
            book.bookUrl = base + "/provisional"
            check(RuleContext(source: src, book: book).get("bid").isEmpty, "provisional URL has no leaked book variables")
            var discarded: RuleContext? = list.forkForBook(book)
            weak var discardedReference = discarded
            _ = discarded?.put("discarded", "private")
            discarded = nil
            check(discardedReference == nil && RuleContext(source: src, book: book).get("discarded").isEmpty, "unbound discarded scope is released without shared records")
        } catch {
            check(false, "BookContextRegression fixture construction: \(error)")
        }
    }
}
