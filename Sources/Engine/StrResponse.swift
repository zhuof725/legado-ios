import Foundation
import JavaScriptCore

/// Native response storage, retaining the existing body/url/code properties.
/// Kotlin StrResponse and Jsoup Connection.Response are distinct contracts.
/// JavaScript wrappers live in JSEngine; a primitive code/url property cannot
/// simultaneously be a same-named callable method without breaking strict equality.
@objc protocol StrResponseExports: JSExport {
    var url: String { get }
    var body: String { get }
    var code: Int { get }
    var length: Int { get }
    func toString() -> String
    func valueOf() -> String
    func isSuccessful() -> Bool
    func headers() -> [String: String]
    func header(_ name: String) -> String
    func cookie(_ name: String) -> String
}

@objc final class StrResponse: NSObject, StrResponseExports {
    let url: String
    let body: String
    let code: Int
    let length: Int
    private let responseHeaders: [String: String]

    /// Zero explicitly means unknown/non-HTTP status, never HTTP success.
    init(url: String, body: String, code: Int = 0, headers: [String: String] = [:]) {
        self.url = url
        self.body = body
        self.code = code
        self.length = body.count
        self.responseHeaders = headers
        super.init()
    }

    convenience init(_ response: HTTPResponseData) {
        self.init(url: response.url, body: response.body,
                  code: response.code, headers: response.headers)
    }

    @objc func toString() -> String { body }
    @objc func valueOf() -> String { body }
    @objc func isSuccessful() -> Bool { (200...299).contains(code) }
    @objc func headers() -> [String: String] { responseHeaders }

    @objc func header(_ name: String) -> String {
        responseHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }

    @objc func cookie(_ name: String) -> String {
        let raw = header("Set-Cookie")
        for item in raw.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 && pair[0].trimmingCharacters(in: .whitespaces) == name {
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
