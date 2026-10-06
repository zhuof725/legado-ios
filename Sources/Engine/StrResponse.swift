import Foundation
import JavaScriptCore

/// Swift equivalent of Legado's StrResponse, exposed to JS.
/// Must be a class (not struct) to work with JSExport.
@objc protocol StrResponseExports: JSExport {
    var url: String { get }
    var body: String { get }
    var code: Int { get }
    var length: Int { get }
    func body() -> String
    func url() -> String
    func code() -> Int
    func toString() -> String
    func valueOf() -> String
    func match(_ pattern: String) -> JSValue?
    func replace(_ pattern: String, _ replacement: String) -> String
    func split(_ separator: String) -> [String]
    func substring(_ start: Int, _ end: Int) -> String
    func indexOf(_ searchString: String) -> Int
    func trim() -> String
}

@objc final class StrResponse: NSObject, StrResponseExports {
    private let _url: String
    private let _body: String
    private let _code: Int
    private let _headers: [String: String]
    private weak var context: JSContext?
    
    init(url: String, body: String, code: Int = 200, headers: [String: String] = [:]) {
        self._url = url
        self._body = body
        self._code = code
        self._headers = headers
        super.init()
    }
    
    // Property accessors for JS (e.g. response.url, response.body, response.code)
    @objc var url: String { _url }
    @objc var body: String { _body }
    @objc var code: Int { _code }
    @objc var length: Int { _body.count }
    
    // Method accessors for JS (e.g. response.url(), response.body(), response.code())
    @objc func url() -> String { _url }
    @objc func body() -> String { _body }
    @objc func code() -> Int { _code }
    
    // Make the object stringify-able in JS (implicit conversion when used as string)
    @objc func toString() -> String { _body }
    @objc func valueOf() -> String { _body }
    
    // String methods that book sources might call on the response object
    @objc func match(_ pattern: String) -> JSValue? {
        let ctx = JSContext.current()
        let script = """
        (function(str, pattern) {
            try {
                var m = pattern.match(/^\\/(.*)\\/([gimuy]*)$/);
                if (m) return str.match(new RegExp(m[1], m[2]));
                return str.match(pattern);
            } catch(e) { return null; }
        })('\(escapeJS(_body))', '\(escapeJS(pattern))');
        """
        return ctx?.evaluateScript(script)
    }
    
    @objc func replace(_ pattern: String, _ replacement: String) -> String {
        _body.replacingOccurrences(of: pattern, with: replacement)
    }
    
    @objc func split(_ separator: String) -> [String] {
        _body.components(separatedBy: separator)
    }
    
    @objc func substring(_ start: Int, _ end: Int) -> String {
        let s = _body.utf16
        let startIdx = s.index(s.startIndex, offsetBy: max(0, start), limitedBy: s.endIndex) ?? s.startIndex
        let endIdx = s.index(s.startIndex, offsetBy: min(s.count, end), limitedBy: s.endIndex) ?? s.endIndex
        return String(s[startIdx..<endIdx])
    }
    
    @objc func indexOf(_ searchString: String) -> Int {
        if let range = _body.range(of: searchString) {
            return _body.distance(from: _body.startIndex, to: range.lowerBound)
        }
        return -1
    }
    
    @objc func trim() -> String {
        _body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // Expose headers if needed by advanced rules
    func header(_ name: String) -> String? {
        _headers.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }
    
    private func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// Extension to convert URLResponse + body into StrResponse
extension StrResponse {
    convenience init(response: URLResponse?, body: String) {
        let http = response as? HTTPURLResponse
        let url = response?.url?.absoluteString ?? ""
        let code = http?.statusCode ?? 200
        let headers = http?.allHeaderFields.reduce(into: [:]) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                result[key] = value
            }
        } ?? [:]
        self.init(url: url, body: body, code: code, headers: headers)
    }
}
