import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Offline, synthetic fixtures only. No URLSession is created or resumed.
/// Each run owns an ephemeral configuration's private in-memory cookie store
/// and a UUID-namespaced .invalid host family. Cleanup deletes only that family.
/// Register manually: CookieStoreRegression.run(check).
/// Requires a Swift/Foundation host; source inspection is not a passing run.
enum CookieStoreRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        guard let storage = configuration.httpCookieStorage else {
            check(false, "private ephemeral cookie storage is available")
            return
        }
        storage.cookieAcceptPolicy = .always
        let parent = "cookie-" + UUID().uuidString.lowercased() + ".invalid"
        let host = "a." + parent
        let sibling = "b." + parent
        let root = "https://" + host
        let other = "https://" + sibling
        let store = SourceCookieStore(storage: storage)
        defer {
            for cookie in storage.cookies ?? [] {
                let domain = cookie.domain.hasPrefix(".")
                    ? String(cookie.domain.dropFirst()) : cookie.domain
                if domain == parent || domain.hasSuffix("." + parent) {
                    storage.deleteCookie(cookie)
                }
            }
        }

        func rejects(_ expected: SourceCookieStore.StoreError, _ label: String,
                     _ action: () throws -> Void) {
            do {
                try action()
                check(false, label)
            } catch let error as SourceCookieStore.StoreError {
                check(error == expected, label)
            } catch {
                check(false, label)
            }
        }
        func fixture(_ name: String, _ domain: String, path: String = "/",
                     secure: Bool = false, expires: Date? = nil) throws {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: "fixture", .domain: domain, .path: path
            ]
            if secure { properties[.secure] = "TRUE" }
            if let expires = expires { properties[.expires] = expires }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw SourceCookieStore.StoreError.invalidCookie
            }
            storage.setCookie(cookie)
            if expires == nil || expires! > Date() {
                check((storage.cookies ?? []).contains {
                    $0.name == name && $0.domain == cookie.domain && $0.path == path
                }, "synthetic scope fixture was accepted")
            }
        }
        func snapshot() -> [String] {
            (storage.cookies ?? []).map {
                [$0.domain, $0.path, $0.name, $0.value, String($0.isSecure)]
                    .joined(separator: "\u{001F}")
            }.sorted()
        }

        do {
            let parsed = try SourceCookieStore.cookieToMap(" token = x=y== ; empty=; dup=old; dup=new; literal=null ")
            check(parsed == ["token": "x=y==", "empty": "", "dup": "new", "literal": "null"],
                  "first equals, empty values, last duplicate and literal null semantics")
            check(try SourceCookieStore.cookieToMap(" \t ").isEmpty, "blank input is an empty map")
            check(try SourceCookieStore.mapToCookie([:]).isEmpty, "empty map serializes to empty string")
            let encoded = try SourceCookieStore.mapToCookie(parsed)
            check(try SourceCookieStore.cookieToMap(encoded) == parsed, "pure conversion round trip")
            check(try SourceCookieStore.mapToCookie(["z": "2", "a": "1"]) == "a=1; z=2",
                  "map serialization has deterministic name order")
            rejects(.invalidCookie, "map rejects header injection") {
                _ = try SourceCookieStore.mapToCookie(["safe": "bad\r\nheader"])
            }
            rejects(.invalidCookie, "map rejects invalid name") {
                _ = try SourceCookieStore.mapToCookie(["bad name": "fixture"])
            }

            try store.setCookie(root, "first=one; stale=two")
            try store.replaceCookie(root, "first=three; token=x=y==; empty=")
            check(store.getKey(root, "stale") == "two" && store.getKey(root, "first") == "three",
                  "replace merges supplied names and preserves omitted names")
            check(store.getKey(root, "token") == "x=y==" && store.getCookie(root).contains("empty="),
                  "storage preserves equals and present empty value")
            try store.setCookie(root, "only=one; only=last")
            check(store.getCookie(root) == "only=last", "set replaces collection and last duplicate wins")
            try store.replaceCookie(root, "")
            check(store.getCookie(root) == "only=last", "empty replace is a no-op")
            check(store.getCookie("http://" + host).isEmpty, "HTTPS writes default to Secure")
            check(store.getCookie(other).isEmpty, "script cookies do not leak to siblings")
            check(store.getCookie("https://child." + host).isEmpty, "script cookies remain host-only")
            check(store.getCookie("https://" + parent).isEmpty, "script cookies do not expand to parent")

            let invalid = ["ok=x; broken", "ok=x; bad name=y", "ok=x; =y", "ok=x; x=bad\r\ny",
                           "ok=x;;b=y", "ok=x;", "ok=x; q=\"quoted\"", "ok=x; q=a,b", "ok=x; q=a\\b"]
            for text in invalid {
                let before = snapshot()
                rejects(.invalidCookie, "malformed set fails before mutation") { try store.setCookie(root, text) }
                check(snapshot() == before, "failed set leaves storage unchanged")
                rejects(.invalidCookie, "malformed replace fails before mutation") { try store.replaceCookie(root, text) }
                check(snapshot() == before, "failed replace leaves storage unchanged")
            }
            for url in ["", "file:///fixture", "https:///", "https://user:pass@" + host,
                        "https://@" + host, "https://" + host + "/bad\npath", "//" + host,
                        "https://." + host, "https://" + host + ":0/",
                        "https://" + host + ":65536/"] {
                let before = snapshot()
                rejects(.invalidURL, "invalid URL write is rejected") { try store.setCookie(url, "x=y") }
                rejects(.invalidURL, "invalid URL removal is rejected") { try store.removeCookie(url) }
                check(store.getCookie(url).isEmpty && snapshot() == before, "invalid URL cannot read or mutate")
            }

            try store.setCookie(other, "other=kept")
            try fixture("parentScope", "." + parent)
            try fixture("only", "." + parent)
            check(store.getKey(root, "only") == "last",
                  "same-path lookup prefers explicit host over parent domain")
            try fixture("pathScope", host, path: "/book")
            try fixture("secureScope", host, secure: true)
            try fixture("expiredScope", host, expires: Date(timeIntervalSinceNow: -3600))
            try fixture("futureScope", host, expires: Date(timeIntervalSinceNow: 3600))
            check(store.getKey(root, "parentScope") == "fixture", "existing parent domain cookie is readable")
            check(store.getKey(root + "/book", "pathScope") == "fixture"
                  && store.getKey(root + "/book/chapter", "pathScope") == "fixture"
                  && store.getKey(root + "/books", "pathScope").isEmpty
                  && store.getKey(root, "pathScope").isEmpty, "path matching respects segment boundaries")
            check(store.getKey("http://" + host, "secureScope").isEmpty
                  && store.getKey(root, "secureScope") == "fixture", "existing Secure scope is respected")
            check(store.getKey(root, "expiredScope").isEmpty
                  && store.getKey(root, "futureScope") == "fixture", "expired cookies are excluded")
            try fixture("only", host, path: "/book")
            check(store.getKey(root + "/book", "only") == "fixture", "longest path wins same-name lookup")
            try store.replaceCookie(root, "only=merged")
            check(store.getKey(root + "/book", "only") == "merged", "replace removes supplied name across exact-host paths")
            try store.setCookie(root, "fresh=one")
            check(store.getKey(root + "/book", "pathScope").isEmpty
                  && store.getKey(root, "parentScope") == "fixture", "set clears exact-host paths but preserves parent cookie")
            try fixture("removePath", host, path: "/book")
            try store.removeCookie(root)
            check(store.getKey(root, "fresh").isEmpty && store.getKey(other, "other") == "kept"
                  && store.getKey(root, "parentScope") == "fixture"
                  && store.getKey(root, "only") == "fixture"
                  && store.getKey(root + "/book", "removePath").isEmpty,
                  "remove clears exact-host paths and preserves sibling and same-name parent records")
            try store.setCookie(root, "clearMe=one")
            try store.setCookie(root, "")
            check(store.getKey(root, "clearMe").isEmpty, "empty set clears explicit host")
            try store.setCookie("http://" + host, "plain=one")
            check(store.getKey("http://" + host, "plain") == "one", "HTTP write is not Secure")
            storage.cookieAcceptPolicy = .never
            let before = snapshot()
            rejects(.storageRejected, "rejecting storage does not report write success") {
                try store.setCookie(root, "rejected=one")
            }
            check(snapshot() == before, "storage rejection does not delete old cookies")
            storage.cookieAcceptPolicy = .always

            let absent = SourceCookieStore(storage: nil)
            check(absent.getCookie(root).isEmpty && absent.getKey(root, "missing").isEmpty,
                  "nil storage reads empty without fallback")
            rejects(.unavailableStorage, "nil storage set fails") { try absent.setCookie(root, "a=b") }
            rejects(.unavailableStorage, "nil storage empty set fails") { try absent.setCookie(root, "") }
            rejects(.unavailableStorage, "nil storage replace fails") { try absent.replaceCookie(root, "a=b") }
            rejects(.unavailableStorage, "nil storage empty replace fails") { try absent.replaceCookie(root, "") }
            rejects(.unavailableStorage, "nil storage removal fails") { try absent.removeCookie(root) }
        } catch {
            // Do not print errors containing fixture data or cookie contents.
            check(false, "CookieStoreRegression unexpected fixture or adapter error")
        }
    }
}
