import Foundation
import JavaScriptCore
import CommonCrypto

/// Bridge object exposed to book-source JS as `java`.
@objc protocol JavaBridgeExports: JSExport {
    func ajax(_ url: String) -> StrResponse
    func connect(_ url: String) -> StrResponse
    func base64Decode(_ s: String) -> String
    func base64Encode(_ s: String) -> String
    func md5Encode(_ s: String) -> String
    func md5Encode16(_ s: String) -> String
    func encodeURI(_ s: String) -> String
    func timeFormat(_ t: Double) -> String
    func log(_ s: String) -> String
    func put(_ key: String, _ value: String) -> String
    func get(_ key: String) -> String
    func hexDecodeToString(_ s: String) -> String
    func hexEncodeToString(_ s: String) -> String
    func toast(_ s: String) -> String
    func longToast(_ s: String) -> String
    func encodeURIComponent(_ s: String) -> String
    func timeFormatUTC(_ t: Double, _ format: String, _ offset: Int) -> String
}

@objc final class JavaBridge: NSObject, JavaBridgeExports {
    static var store: [String: String] = [:]
    static let lock = NSLock()

    func ajax(_ url: String) -> StrResponse {
        let sem = DispatchSemaphore(value: 0)
        var result: (String, String) = ("", "")
        let au = AnalyzeUrl(rawUrl: url)
        Task.detached {
            result = (try? await au.fetch()) ?? ("", "")
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        // result.0 = body, result.1 = final URL
        return StrResponse(url: result.1.isEmpty ? url : result.1, body: result.0)
    }
    
    func connect(_ url: String) -> StrResponse {
        return ajax(url)
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
    func hexDecodeToString(_ s: String) -> String {
        var bytes: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            if let b = UInt8(s[i..<j], radix: 16) { bytes.append(b) }
            i = j
        }
        return String(data: Data(bytes), encoding: .utf8) ?? ""
    }
    func hexEncodeToString(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }
    func toast(_ s: String) -> String { print("[toast] \(s)"); return s }
    func longToast(_ s: String) -> String { print("[toast] \(s)"); return s }
    func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? s
    }
    func timeFormatUTC(_ t: Double, _ format: String, _ offset: Int) -> String {
        let f = DateFormatter(); f.dateFormat = format.isEmpty ? "yyyy/MM/dd HH:mm" : format
        f.timeZone = TimeZone(secondsFromGMT: offset * 3600)
        return f.string(from: Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t))
    }
}

final class JSEngine {
    static let shared = JSEngine()
    /// 当前正在执行的书源（供 JS 里的 `source` 对象使用）
    static var currentSource: BookSource?

    private static let prelude = """
    var cookie={getCookie:function(){return ''},getKey:function(){return ''},removeCookie:function(){},setCookie:function(){},replaceCookie:function(){}};
    var cache={get:function(k){return java.get(k)},put:function(k,v){return java.put(k,String(v))},getFromMemory:function(k){return java.get(k)},putMemory:function(k,v){return java.put(k,String(v))}};
    var source={bookSourceUrl:'',bookSourceName:'',bookSourceComment:'',getKey:function(){return this.bookSourceUrl},getVariable:function(){return java.get('__var_'+this.bookSourceUrl)},setVariable:function(v){java.put('__var_'+this.bookSourceUrl,String(v))},put:function(k,v){return java.put(k,String(v))},get:function(k){return java.get(k)}};
    var book={name:'',author:'',bookUrl:'',tocUrl:'',getVariable:function(){return ''},setVariable:function(){}};
    var chapter={title:'',url:'',index:0};
    java.startBrowserAwait=function(u,t){return java.ajax(String(u))};
    java.startBrowser=function(u,t){return ''};
    java.webView=function(h,u,js){return java.ajax(String(u))};
    java.ajaxAll=function(arr){var o=[];for(var i=0;i<arr.length;i++){o.push(java.ajax(String(arr[i])));}return o;};
    java.getString=function(r){return (typeof __ruleGetString==='function')?String(__ruleGetString(String(r))):''};
    java.getStringList=function(r){var s=java.getString(r);return s?s.split('\\n'):[]};
    java.getElement=function(r){return (typeof __ruleGetElements==='function')?__ruleGetElements(String(r))[0]:null};
    java.getElements=function(r){return (typeof __ruleGetElements==='function')?__ruleGetElements(String(r)):[]};
    java.setContent=function(c){result=c};
    java.getCookie=function(){return ''};
    java.utf8ToGbk=function(s){return s};
    java.t2s=function(s){return s};java.s2t=function(s){return s};
    java.randomUUID=function(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0;return (c=='x'?r:(r&3|8)).toString(16)})};
    """

    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in print("[JS error] \(e?.toString() ?? "")") }
        ctx.setObject(JavaBridge(), forKeyedSubscript: "java" as NSString)
        ctx.evaluateScript(JSEngine.prelude)
        if let s = JSEngine.currentSource, let src = ctx.objectForKeyedSubscript("source") {
            src.setObject(s.bookSourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
            src.setObject(s.bookSourceName, forKeyedSubscript: "bookSourceName" as NSString)
            src.setObject(s.bookSourceComment ?? "", forKeyedSubscript: "bookSourceComment" as NSString)
            ctx.objectForKeyedSubscript("book")?.setObject(s.bookSourceUrl, forKeyedSubscript: "origin" as NSString)
        }
        return ctx
    }

    /// Evaluate a JS snippet with `result`, `baseUrl`, `book`, `key`, `page` in scope.
    func eval(_ script: String, result: Any? = nil, baseUrl: String? = nil,
              vars: [String: Any] = [:], jsLib: String? = nil,
              rule: AnalyzeRule? = nil, ruleInput: Any? = nil) -> Any? {
        let ctx = makeContext()
        if let r = rule {
            let input = ruleInput
            let gs: @convention(block) (String) -> String = { s in r.getString(s, from: input) }
            let ge: @convention(block) (String) -> [Any] = { s in r.getElements(s, from: input).map { AnalyzeRule.jsValue($0) } }
            ctx.setObject(gs, forKeyedSubscript: "__ruleGetString" as NSString)
            ctx.setObject(ge, forKeyedSubscript: "__ruleGetElements" as NSString)
        }
        if let lib = jsLib, !lib.isEmpty, !lib.hasPrefix("{") { ctx.evaluateScript(lib) }
        ctx.setObject(result ?? "", forKeyedSubscript: "result" as NSString)
        ctx.setObject(baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        for (k, v) in vars { ctx.setObject(v, forKeyedSubscript: k as NSString) }
        guard let v = ctx.evaluateScript(script), !v.isUndefined, !v.isNull else { return nil }
        if v.isString || v.isNumber || v.isBoolean { return v.toString() }
        if v.isArray { return v.toArray() }
        return v.toObject() ?? v.toString()
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
