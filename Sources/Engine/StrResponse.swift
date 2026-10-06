import Foundation
import JavaScriptCore

/// Legado `StrResponse` 的 iOS 对应类型。
/// 原版在 JS 中通过 body()、url、code、header() 使用它；
/// JavaScriptCore 的方法名不能同时与 Swift 属性重名，因此 body()/url()
/// 由 JSEngine 的 JS 包装层提供，原生对象保留属性。
@objc protocol StrResponseExports: JSExport {
    var url: String { get }
    var body: String { get }
    var code: Int { get }
    var length: Int { get }
    func toString() -> String
    func valueOf() -> String
    func header(_ name: String) -> String
    func cookie(_ name: String) -> String
}

@objc final class StrResponse: NSObject, StrResponseExports {
    let url: String
    let body: String
    let code: Int
    let length: Int
    private let headers: [String: String]

    init(url: String, body: String, code: Int = 200, headers: [String: String] = [:]) {
        self.url = url
        self.body = body
        self.code = code
        self.length = body.count
        self.headers = headers
        super.init()
    }

    @objc func toString() -> String { body }
    @objc func valueOf() -> String { body }

    @objc func header(_ name: String) -> String {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
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
