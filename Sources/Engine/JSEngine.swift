import Foundation
import JavaScriptCore
import CommonCrypto
import SwiftSoup

/// Bridge object exposed to book-source JS as `java`.
@objc protocol JavaBridgeExports: JSExport {
    /// Legado 约定：ajax 直接返回响应正文。
    func ajax(_ url: String) -> String
    /// 原生响应对象入口，由 JS 包装为 java.connect。
    func connectNative(_ url: String) -> StrResponse
    func base64Decode(_ s: String) -> String
    func base64Encode(_ s: String) -> String
    func md5Encode(_ s: String) -> String
    func md5Encode16(_ s: String) -> String
    func encodeURI(_ s: String) -> String
    func timeFormat(_ t: Double) -> String
    func log(_ s: String) -> String
    func storePut(_ key: String, _ value: String) -> String
    func storeGet(_ key: String) -> String
    func httpGetNative(_ url: String, _ headersJSON: String) -> StrResponse
    func httpPostNative(_ url: String, _ body: String, _ headersJSON: String) -> StrResponse
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
    let context: RuleContext?

    init(context: RuleContext? = nil) {
        self.context = context
        super.init()
    }

    func ajax(_ url: String) -> String {
        let response = connectNative(url)
        #if canImport(UIKit) && canImport(WebKit)
        if WebViewSupport.isChallenge(response.body) {
            let sem = DispatchSemaphore(value: 0)
            var body = response.body
            Task { @MainActor in
                if let r = try? await WebViewLoader.load(url: response.url, headers: [:], allowInteractive: true) {
                    body = r.0
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 35)
            return body
        }
        #endif
        return response.body
    }

    func connectNative(_ url: String) -> StrResponse {
        let sem = DispatchSemaphore(value: 0)
        var result: (String, String) = ("", "")
        var au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl, sourceHeader: context?.source?.header, context: context)
        Task.detached {
            result = (try? await au.fetch()) ?? ("", "")
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        return StrResponse(url: result.1.isEmpty ? url : result.1, body: result.0)
    }

    func ajaxAllNative(_ urls: [String]) -> [StrResponse] {
        urls.map { connectNative($0) }
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
    func storePut(_ key: String, _ value: String) -> String {
        JavaBridge.lock.lock(); JavaBridge.store[key] = value; JavaBridge.lock.unlock(); return value
    }
    func storeGet(_ key: String) -> String {
        JavaBridge.lock.lock(); defer { JavaBridge.lock.unlock() }
        return JavaBridge.store[key] ?? ""
    }

    func httpGetNative(_ url: String, _ headersJSON: String) -> StrResponse {
        let au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl,
                            sourceHeader: headersJSON, context: context)
        return fetchResponse(au, fallbackURL: url)
    }

    func httpPostNative(_ url: String, _ body: String, _ headersJSON: String) -> StrResponse {
        var au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl,
                            sourceHeader: headersJSON, context: context)
        au.method = "POST"
        au.body = body
        return fetchResponse(au, fallbackURL: url)
    }

    private func fetchResponse(_ au: AnalyzeUrl, fallbackURL: String) -> StrResponse {
        let sem = DispatchSemaphore(value: 0)
        var result: (String, String) = ("", "")
        Task.detached {
            result = (try? await au.fetch()) ?? ("", "")
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 25)
        return StrResponse(url: result.1.isEmpty ? fallbackURL : result.1, body: result.0)
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
    var cache={get:function(k){return java.storeGet(k)},put:function(k,v){return java.storePut(k,String(v))},getFromMemory:function(k){return java.storeGet(k)},putMemory:function(k,v){return java.storePut(k,String(v))}};
    var source={bookSourceUrl:'',bookSourceName:'',bookSourceComment:'',getKey:function(){return this.bookSourceUrl},getVariable:function(){return java.storeGet('__var_'+this.bookSourceUrl)},setVariable:function(v){java.storePut('__var_'+this.bookSourceUrl,String(v))},put:function(k,v){return java.storePut(k,String(v))},get:function(k){return java.storeGet(k)}};
    var book={name:'',author:'',bookUrl:'',tocUrl:'',getVariable:function(){return ''},setVariable:function(){}};
    var chapter={title:'',url:'',index:0};
    var Packages={org:{jsoup:{Jsoup:{parse:function(html){
        var root={select:function(q){
            var arr=typeof __ruleGetElements==='function'?__ruleGetElements('@css:'+q):[];
            return {size:function(){return arr.length},get:function(i){return arr[i]},toArray:function(){return arr},length:arr.length};
        },text:function(){return String(html)},html:function(){return String(html)},toString:function(){return String(html)}};
        return root;
    }}}}};
    function __response(r){
        if(!r){return null;}
        return {
            url:r.url,
            code:r.code,
            length:r.length,
            body:function(){return r.body},
            header:function(k){return r.header(k)},
            toString:function(){return r.body},
            valueOf:function(){return r.body}
        };
    }
    java.connect=function(u){return __response(java.connectNative(String(u)))};
    java.ajaxAll=function(arr){var o=[];for(var i=0;i<arr.length;i++){o.push(__response(java.connectNative(String(arr[i]))));}return o;};
    java.startBrowserAwait=function(u,t){return java.connect(String(u))};
    java.startBrowser=function(u,t){return ''};
    java.webView=function(h,u,js){return java.ajax(String(u))};
    java.get=function(u,h){return __response(java.httpGetNative(String(u),JSON.stringify(h||{})))};
    java.post=function(u,b,h){return __response(java.httpPostNative(String(u),String(b),JSON.stringify(h||{})))};
    java.getCookie=function(u,k){return ''};
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

    private func makeContext(_ context: RuleContext? = nil) -> JSContext {
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in print("[JS error] \(e?.toString() ?? "")") }
        ctx.setObject(JavaBridge(context: context), forKeyedSubscript: "java" as NSString)
        ctx.evaluateScript(JSEngine.prelude)
        let source = context?.source ?? JSEngine.currentSource
        if let s = source, let src = ctx.objectForKeyedSubscript("source") {
            src.setObject(s.bookSourceUrl, forKeyedSubscript: "bookSourceUrl" as NSString)
            src.setObject(s.bookSourceName, forKeyedSubscript: "bookSourceName" as NSString)
            src.setObject(s.bookSourceComment ?? "", forKeyedSubscript: "bookSourceComment" as NSString)
        }
        if let b = context?.book, let book = ctx.objectForKeyedSubscript("book") {
            book.setObject(b.bookUrl, forKeyedSubscript: "bookUrl" as NSString)
            book.setObject(b.tocUrl ?? "", forKeyedSubscript: "tocUrl" as NSString)
            book.setObject(b.origin, forKeyedSubscript: "origin" as NSString)
            book.setObject(b.originName, forKeyedSubscript: "originName" as NSString)
            book.setObject(b.name, forKeyedSubscript: "name" as NSString)
            book.setObject(b.author, forKeyedSubscript: "author" as NSString)
            book.setObject(b.kind ?? "", forKeyedSubscript: "kind" as NSString)
            book.setObject(b.intro ?? "", forKeyedSubscript: "intro" as NSString)
            book.setObject(b.durChapterIndex, forKeyedSubscript: "durChapterIndex" as NSString)
            book.setObject(b.durChapterTitle ?? "", forKeyedSubscript: "durChapterTitle" as NSString)
        }
        if let c = context?.chapter, let chapter = ctx.objectForKeyedSubscript("chapter") {
            chapter.setObject(c.url, forKeyedSubscript: "url" as NSString)
            chapter.setObject(c.title, forKeyedSubscript: "title" as NSString)
            chapter.setObject(c.index, forKeyedSubscript: "index" as NSString)
            chapter.setObject(c.url, forKeyedSubscript: "baseUrl" as NSString)
        }
        return ctx
    }

    /// Evaluate a JS snippet with `result`, `baseUrl`, `book`, `chapter`, `key`, `page` in scope.
    func eval(_ script: String, result: Any? = nil, baseUrl: String? = nil,
              vars: [String: Any] = [:], jsLib: String? = nil,
              rule: AnalyzeRule? = nil, ruleInput: Any? = nil,
              context: RuleContext? = nil) -> Any? {
        let ctx = makeContext(context)
        if let c = context {
            let put: @convention(block) (String, String) -> String = { c.put($0, $1) }
            let get: @convention(block) (String) -> String = { c.get($0) }
            ctx.setObject(put, forKeyedSubscript: "__contextPut" as NSString)
            ctx.setObject(get, forKeyedSubscript: "__contextGet" as NSString)
        }
        if let r = rule {
            let input = ruleInput
            let gs: @convention(block) (String) -> String = { s in r.getString(s, from: input) }
            let ge: @convention(block) (String) -> [Any] = { s in
                r.getElements(s, from: input).map { value in
                    if let element = value as? Element { return JSNodeBridge(element) }
                    if let list = value as? [Element] { return JSNodeListBridge(list) }
                    return AnalyzeRule.jsValue(value)
                }
            }
            ctx.setObject(gs, forKeyedSubscript: "__ruleGetString" as NSString)
            ctx.setObject(ge, forKeyedSubscript: "__ruleGetElements" as NSString)
        }
        if let lib = jsLib, !lib.isEmpty, !lib.hasPrefix("{") { ctx.evaluateScript(lib) }
        ctx.setObject(result ?? "", forKeyedSubscript: "result" as NSString)
        ctx.setObject(baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(result ?? "", forKeyedSubscript: "src" as NSString)
        for (k, v) in vars { ctx.setObject(v, forKeyedSubscript: k as NSString) }
        guard let v = ctx.evaluateScript(script), !v.isUndefined, !v.isNull else { return nil }
        if v.isString || v.isNumber || v.isBoolean { return v.toString() }
        if v.isArray { return v.toArray() }
        return v.toObject() ?? v.toString()
    }

    func evalString(_ script: String, result: Any? = nil, baseUrl: String? = nil,
                    vars: [String: Any] = [:], context: RuleContext? = nil) -> String? {
        guard let v = eval(script, result: result, baseUrl: baseUrl, vars: vars, context: context) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
            return String(data: d, encoding: .utf8)
        }
        return "\(v)"
    }
}
