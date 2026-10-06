import Foundation
import JavaScriptCore
import CommonCrypto

/// Bridge object exposed to book-source JS as `java`.
@objc protocol JavaBridgeExports: JSExport {
    func ajax(_ url: String) -> String
    func base64Decode(_ s: String) -> String
    func base64Encode(_ s: String) -> String
    func md5Encode(_ s: String) -> String
    func md5Encode16(_ s: String) -> String
    func encodeURI(_ s: String) -> String
    func timeFormat(_ t: Double) -> String
    func log(_ s: String) -> String
    func put(_ key: String, _ value: String) -> String
    func get(_ key: String) -> String
}

@objc final class JavaBridge: NSObject, JavaBridgeExports {
    static var store: [String: String] = [:]
    static let lock = NSLock()

    func ajax(_ url: String) -> String {
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        let au = AnalyzeUrl(rawUrl: url)
        Task.detached {
            result = (try? await au.fetch().0) ?? ""
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        return result
    }
    func base64Decode(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    func base64Encode(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    func md5Encode(_ s: String) -> String {
        let d = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        d.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(d.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    func md5Encode16(_ s: String) -> String {
        let m = md5Encode(s)
        let start = m.index(m.startIndex, offsetBy: 8)
        return String(m[start..<m.index(start, offsetBy: 16)])
    }
    func encodeURI(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
    func timeFormat(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t))
    }
    func log(_ s: String) -> String { print("[JS] \(s)"); return s }
    func put(_ key: String, _ value: String) -> String {
        JavaBridge.lock.lock(); JavaBridge.store[key] = value; JavaBridge.lock.unlock(); return value
    }
    func get(_ key: String) -> String {
        JavaBridge.lock.lock(); defer { JavaBridge.lock.unlock() }
        return JavaBridge.store[key] ?? ""
    }
}

final class JSEngine {
    static let shared = JSEngine()
    private let queue = DispatchQueue(label: "legado.js")

    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in print("[JS error] \(e?.toString() ?? "")") }
        ctx.setObject(JavaBridge(), forKeyedSubscript: "java" as NSString)
        ctx.evaluateScript("var cookie={getCookie:function(){return ''}};var cache={get:function(k){return java.get(k)},put:function(k,v){return java.put(k,v)}};")
        return ctx
    }

    /// Evaluate a JS snippet with `result`, `baseUrl`, `book`, `key`, `page` in scope.
    func eval(_ script: String, result: Any? = nil, baseUrl: String? = nil,
              vars: [String: Any] = [:], jsLib: String? = nil) -> Any? {
        queue.sync {
            let ctx = makeContext()
            if let lib = jsLib, !lib.isEmpty, !lib.hasPrefix("{") { ctx.evaluateScript(lib) }
            ctx.setObject(result ?? "", forKeyedSubscript: "result" as NSString)
            ctx.setObject(baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
            for (k, v) in vars { ctx.setObject(v, forKeyedSubscript: k as NSString) }
            guard let v = ctx.evaluateScript(script), !v.isUndefined, !v.isNull else { return nil }
            if v.isString || v.isNumber || v.isBoolean { return v.toString() }
            if v.isArray { return v.toArray() }
            return v.toObject() ?? v.toString()
        }
    }

    func evalString(_ script: String, result: Any? = nil, baseUrl: String? = nil) -> String? {
        guard let v = eval(script, result: result, baseUrl: baseUrl) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
            return String(data: d, encoding: .utf8)
        }
        return "\(v)"
    }
}
