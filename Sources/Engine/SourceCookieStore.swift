import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App-internal request-Cookie compatibility, not a Set-Cookie parser.
/// Storage is explicitly injected; nil never falls back to a global store.
/// Kotlin CookieStore.kt aggregates by NetworkUtils.getSubDomain and persists
/// strings in DB/cache. This adapter instead uses Foundation URL scope, never
/// calculates a registrable domain, and never touches WebView or credentials.
///
/// Parsing differences from Kotlin: empty values are retained; malformed pairs
/// throw instead of being skipped; duplicates use the last value; whitespace
/// surrounding each name/value is trimmed (SP/HTAB only). Empty input is an
/// empty map; mapToCookie returns "" rather than null and sorts names. Literal
/// "null" is an ordinary value. No random eviction at 4096 characters.
///
/// set replaces ALL cookies whose explicit domain equals the current host,
/// across paths; replace replaces only supplied names in that same scope.
/// Parent-domain cookies are never copied, changed or deleted. New cookies use
/// the explicit host, root path, session lifetime and Secure on HTTPS.
/// An empty set clears that host; an empty replace is a no-op, but still requires
/// valid URL and available storage. remove clears only that explicit host.
///
/// Foundation storage is not transactional. Input and cookie construction are
/// validated before mutation. This lock serializes calls through this instance,
/// not other users of the injected storage. The owner must serialize external
/// writers. Storage rejection is reported, with best-effort scope rollback.
final class SourceCookieStore {
    enum StoreError: Error, Equatable {
        case invalidURL
        case invalidCookie
        case unavailableStorage
        case storageRejected
    }

    private let storage: HTTPCookieStorage?
    private let lock = NSLock()

    init(storage: HTTPCookieStorage?) {
        self.storage = storage
    }

    /// Invalid URLs and unavailable storage read as empty; writes throw.
    func getCookie(_ url: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let target = try? Self.target(url), let storage = storage else { return "" }
        return visibleCookies(storage, target).map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// For same-name cookies, prefer the longest matching path, then the
    /// explicit host over a parent domain. Missing and empty both return "".
    func getKey(_ url: String, _ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let target = try? Self.target(url), let storage = storage else { return "" }
        return visibleCookies(storage, target).first { $0.name == key }?.value ?? ""
    }

    func setCookie(_ url: String, _ string: String) throws {
        try write(url, string, replacingAll: true)
    }

    func replaceCookie(_ url: String, _ string: String) throws {
        try write(url, string, replacingAll: false)
    }

    func removeCookie(_ url: String) throws {
        try write(url, "", replacingAll: true)
    }

    static func cookieToMap(_ cookie: String) throws -> [String: String] {
        guard !cookie.contains("\r"), !cookie.contains("\n") else {
            throw StoreError.invalidCookie
        }
        if trim(cookie).isEmpty { return [:] }
        var result: [String: String] = [:]
        // Empty segments (including a trailing semicolon) are rejected.
        for item in cookie.split(separator: ";", omittingEmptySubsequences: false) {
            guard let equals = item.firstIndex(of: "=") else { throw StoreError.invalidCookie }
            let name = trim(String(item[..<equals]))
            let value = trim(String(item[item.index(after: equals)...]))
            try validate(name, value)
            result[name] = value
        }
        return result
    }

    static func mapToCookie(_ map: [String: String]) throws -> String {
        for (name, value) in map { try validate(name, value) }
        return map.keys.sorted().map { "\($0)=\(map[$0]!)" }.joined(separator: "; ")
    }

    private static func trim(_ string: String) -> String {
        string.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func validate(_ name: String, _ value: String) throws {
        let punctuation = "!#$%&'*+-.^_`|~"
        guard !name.isEmpty, name.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte)
                || (48...57).contains(byte) || punctuation.utf8.contains(byte)
        }), value.utf8.allSatisfy({ byte in
            // RFC 6265 cookie-octet: includes '='; excludes control characters,
            // whitespace, quotes, comma, semicolon and backslash.
            byte == 0x21 || (0x23...0x2B).contains(byte)
                || (0x2D...0x3A).contains(byte) || (0x3C...0x5B).contains(byte)
                || (0x5D...0x7E).contains(byte)
        }) else { throw StoreError.invalidCookie }
    }

    private static func target(_ string: String) throws -> URL {
        guard !string.isEmpty,
              !string.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
              }), !string.contains("\\"),
              let parts = URLComponents(string: string),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty,
              !host.contains("%"), !host.hasPrefix("."), !host.contains(".."),
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url, url.host != nil else { throw StoreError.invalidURL }
        return url
    }

    private func visibleCookies(_ storage: HTTPCookieStorage, _ url: URL) -> [HTTPCookie] {
        let now = Date()
        let host = url.host!.lowercased()
        // Foundation supplies domain/path/Secure applicability. Explicit checks
        // protect expiry and host-only boundaries across Foundation variants.
        return (storage.cookies(for: url) ?? []).filter { cookie in
            let domain = cookie.domain.lowercased()
            let explicitHost = !domain.hasPrefix(".")
            let path = url.path.isEmpty ? "/" : url.path
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let matchesPath = path == cookiePath || (path.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return (!explicitHost || domain == host)
                && (!cookie.isSecure || url.scheme?.lowercased() == "https")
                && (cookie.expiresDate.map { $0 > now } ?? true)
                && matchesPath
                && (try? Self.validate(cookie.name, cookie.value)) != nil
        }.sorted {
            if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
            let leftExact = $0.domain.lowercased() == host
            let rightExact = $1.domain.lowercased() == host
            if leftExact != rightExact { return leftExact }
            if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
            if $0.name != $1.name { return $0.name < $1.name }
            if $0.domain != $1.domain { return $0.domain < $1.domain }
            return $0.value < $1.value
        }
    }

    private func write(_ stringURL: String, _ string: String, replacingAll: Bool) throws {
        let url = try Self.target(stringURL)
        let values = try Self.cookieToMap(string)
        let host = url.host!.lowercased()
        // Construct the entire batch before deleting anything.
        let additions: [HTTPCookie] = try values.keys.sorted().map { name in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: values[name]!, .domain: host,
                .path: "/", .originURL: url
            ]
            if url.scheme?.lowercased() == "https" { properties[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: properties),
                  cookie.domain.lowercased() == host,
                  cookie.path == "/", cookie.name == name,
                  cookie.value == values[name],
                  cookie.isSecure == (url.scheme?.lowercased() == "https") else {
                throw StoreError.invalidCookie
            }
            return cookie
        }
        lock.lock()
        defer { lock.unlock() }
        guard let storage = storage else { throw StoreError.unavailableStorage }
        if !additions.isEmpty && storage.cookieAcceptPolicy == .never {
            throw StoreError.storageRejected
        }
        let removed = (storage.cookies ?? []).filter {
            $0.domain.lowercased() == host && (replacingAll || values[$0.name] != nil)
        }
        for cookie in removed { storage.deleteCookie(cookie) }
        for cookie in additions { storage.setCookie(cookie) }
        let current = (storage.cookies ?? []).filter {
            $0.domain.lowercased() == host && (replacingAll || values[$0.name] != nil)
        }
        let accepted = current.count == additions.count && additions.allSatisfy { expected in
            current.contains {
                $0.name == expected.name && $0.value == expected.value
                    && $0.path == expected.path && $0.isSecure == expected.isSecure
            }
        }
        guard accepted else {
            for cookie in current { storage.deleteCookie(cookie) }
            for cookie in removed { storage.setCookie(cookie) }
            throw StoreError.storageRejected
        }
    }
}
