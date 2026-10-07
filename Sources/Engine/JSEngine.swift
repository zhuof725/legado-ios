import Foundation
import JavaScriptCore
import CommonCrypto
import SwiftSoup

/// A single-request result slot. Every access is locked; closing on timeout
/// rejects late completion rather than letting a detached task mutate returned state.
private final class HTTPBridgeWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<HTTPResponseData, Error>?
    private var closed = false

    private func finish(_ value: Result<HTTPResponseData, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, result == nil else { return }
        result = value
        semaphore.signal()
    }

    private func take(timedOut: Bool) -> Result<HTTPResponseData, Error> {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        defer { result = nil }
        if timedOut { return .failure(URLError(.timedOut)) }
        return result ?? .failure(URLError(.unknown))
    }

    static func run(timeout: TimeInterval,
                    operation: @escaping @Sendable () async throws -> HTTPResponseData) throws -> HTTPResponseData {
        let slot = HTTPBridgeWaiter()
        let task = Task.detached {
            do {
                try Task.checkCancellation()
                let response = try await operation()
                try Task.checkCancellation()
                slot.finish(.success(response))
            } catch {
                slot.finish(.failure(error))
            }
        }
        let timedOut = slot.semaphore.wait(timeout: .now() + max(0, timeout)) == .timedOut
        let result = slot.take(timedOut: timedOut)
        if timedOut { task.cancel() }
        return try result.get()
    }
}

/// Bridge object exposed to book-source JS as `java`.
@objc protocol JavaBridgeExports: JSExport {
    /// Legado 约定：ajax 直接返回响应正文。
    func ajax(_ url: String) -> String
    /// 原生响应对象入口，由 JS 包装为 java.connect。
    func connectNative(_ url: String) -> StrResponse?
    func base64Decode(_ s: String) -> String
    func base64Encode(_ s: String) -> String
    func md5Encode(_ s: String) -> String
    func md5Encode16(_ s: String) -> String
    func encodeURI(_ s: String) -> String
    func timeFormat(_ t: Double) -> String
    func log(_ s: String) -> String
    func storePut(_ key: String, _ value: String) -> String
    func storeGet(_ key: String) -> String
    func httpGetNative(_ url: String, _ headersJSON: String) -> StrResponse?
    func httpPostNative(_ url: String, _ body: String, _ headersJSON: String) -> StrResponse?
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
    private let session: URLSession
    private let responseTimeout: TimeInterval

    init(context: RuleContext? = nil, session: URLSession = .shared,
         responseTimeout: TimeInterval = 25) {
        self.context = context
        self.session = session
        self.responseTimeout = responseTimeout
        super.init()
    }

    func ajax(_ url: String) -> String {
        // AnalyzeUrl owns the existing verification path. Do not load the same
        // challenge again here; failures set the current JavaScript exception.
        return connectNative(url)?.body ?? ""
    }

    func connectNative(_ url: String) -> StrResponse? {
        let au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl,
                            sourceHeader: context?.source?.header, context: context,
                            jsLib: context?.source?.jsLib)
        return fetchResponse(au, fallbackURL: url)
    }

    func ajaxAllNative(_ urls: [String]) -> [StrResponse] {
        var responses: [StrResponse] = []
        for url in urls {
            guard let response = connectNative(url) else { return [] }
            responses.append(response)
        }
        return responses
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

    func httpGetNative(_ url: String, _ headersJSON: String) -> StrResponse? {
        let au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl,
                            sourceHeader: headersJSON, context: context, jsLib: context?.source?.jsLib)
        return fetchResponse(au, fallbackURL: url)
    }

    func httpPostNative(_ url: String, _ body: String, _ headersJSON: String) -> StrResponse? {
        var au = AnalyzeUrl(rawUrl: url, baseUrl: context?.source?.bookSourceUrl,
                            sourceHeader: headersJSON, context: context)
        au.method = "POST"
        au.body = body
        return fetchResponse(au, fallbackURL: url)
    }

    private func fetchResponse(_ au: AnalyzeUrl, fallbackURL: String) -> StrResponse? {
        let request = au
        let requestSession = session
        do {
            let response = try HTTPBridgeWaiter.run(timeout: responseTimeout) {
                try await request.fetchResponse(session: requestSession)
            }
            return StrResponse(response)
        } catch {
            // This executes on the calling JS thread, never the detached task.
            // HTTP 4xx/5xx do not enter this branch: they retain body and metadata.
            let nativeError = error as NSError
            let timedOut = nativeError.domain == NSURLErrorDomain
                && nativeError.code == URLError.timedOut.rawValue
            if let jsContext = JSContext.current() {
                let exception = JSValue(newErrorFromMessage: timedOut
                    ? "HTTP request timed out"
                    : "HTTP transport failed: \(nativeError.localizedDescription)", in: jsContext)
                exception?.setObject(timedOut ? "TimeoutError" : "NetworkError",
                                     forKeyedSubscript: "name" as NSString)
                exception?.setObject(nativeError.domain, forKeyedSubscript: "domain" as NSString)
                exception?.setObject(nativeError.code, forKeyedSubscript: "nativeCode" as NSString)
                exception?.setObject(fallbackURL, forKeyedSubscript: "url" as NSString)
                jsContext.exception = exception
            }
            // Direct native callers receive nil, never a fabricated HTTP 200.
            return nil
        }
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
    func toast(_ s: String) -> String { ToastCenter.post(s); return s }
    func longToast(_ s: String) -> String { ToastCenter.post(s); return s }
    func encodeURIComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? s
    }
    func timeFormatUTC(_ t: Double, _ format: String, _ offset: Int) -> String {
        let f = DateFormatter(); f.dateFormat = format.isEmpty ? "yyyy/MM/dd HH:mm" : format
        f.timeZone = TimeZone(secondsFromGMT: offset * 3600)
        return f.string(from: Date(timeIntervalSince1970: t > 1e12 ? t / 1000 : t))
    }
}

/// JS 里 java.toast / longToast 的消息出口：界面订阅 handler 即可显示；没有订阅者时只丢弃。
enum ToastCenter {
    private static var browserHandler: ((String, String) -> Void)?
    static func setBrowserHandler(_ h: ((String, String) -> Void)?) { lock.lock(); browserHandler = h; lock.unlock() }
    static func openBrowser(_ url: String, _ title: String) { lock.lock(); let h = browserHandler; lock.unlock(); h?(url, title) }
    private static let lock = NSLock()
    private static var handler: ((String) -> Void)?
    static func setHandler(_ h: ((String) -> Void)?) { lock.lock(); handler = h; lock.unlock() }
    static func post(_ message: String) {
        lock.lock(); let h = handler; lock.unlock()
        h?(message)
    }
}

final class JSEngine {
    static let shared = JSEngine()
    private let session: URLSession
    private let responseTimeout: TimeInterval

    /// Instance-local injection keeps offline tests away from the shared session.
    init(session: URLSession = .shared, responseTimeout: TimeInterval = 25) {
        self.session = session
        self.responseTimeout = responseTimeout
    }

    /// 登录信息持久化到 Application Support（重启保留），按书源完整标识隔离。
    static let loginStore = SourceLoginStore(
        backing: PersistentLoginBackingStore(fileURL: PersistentLoginBackingStore.defaultFileURL()),
        cookieReplacer: { key, cookie in
            let url = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
            try SourceCookieStore(storage: HTTPCookieStorage.shared).replaceCookie(url, cookie)
        },
        cookieRemover: { key in
            let url = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
            try SourceCookieStore(storage: HTTPCookieStorage.shared).removeCookie(url)
        })

    /// 当前正在执行的书源（供 JS 里的 `source` 对象使用）
    static var currentSource: BookSource?

    private static let prelude = """
    (function(){var __jp=JSON.parse;JSON.parse=function(s,r){if(s!==null&&typeof s==='object'){return s;}return __jp(String(s),r);};})();
    var cookie={
        getCookie:function(u){return String(__cookieGet(String(u)));},
        getKey:function(u,k){return String(__cookieGetKey(String(u),String(k)));},
        // Kotlin returns Unit: template side effects must not insert "true" into URLs.
        setCookie:function(u,v){__cookieSet(String(u),v==null?'':String(v));},
        replaceCookie:function(u,v){__cookieReplace(String(u),v==null?'':String(v));},
        removeCookie:function(u){__cookieRemove(String(u));},
        cookieToMap:function(v){
            var parsed=JSON.parse(String(__cookieToMap(v==null?'':String(v))));
            var map=Object.create(null);
            Object.keys(parsed).forEach(function(k){map[k]=parsed[k];});
            return map;
        },
        mapToCookie:function(v){
            if(v==null){return null;}
            if(typeof v!=='object' || Array.isArray(v)){throw new TypeError('Cookie map must be an object');}
            var map=Object.create(null);
            Object.keys(v).forEach(function(k){
                if(typeof v[k]!=='string'){throw new TypeError('Cookie map values must be strings');}
                map[k]=v[k];
            });
            if(Object.keys(map).length===0){return null;}
            return String(__cookieFromMap(JSON.stringify(map)));
        }
    };
    var cache={get:function(k){return java.storeGet(k)},put:function(k,v){return java.storePut(k,String(v))},getFromMemory:function(k){return java.storeGet(k)},putMemory:function(k,v){return java.storePut(k,String(v))}};
    var source={bookSourceUrl:'',bookSourceName:'',bookSourceComment:'',getKey:function(){return this.bookSourceUrl},getVariable:function(){return java.storeGet('__var_'+this.bookSourceUrl)},setVariable:function(v){java.storePut('__var_'+this.bookSourceUrl,String(v))},put:function(k,v){return java.storePut(k,String(v))},get:function(k){return java.storeGet(k)},
        getLoginInfoMap:function(){var s=String(__loginInfoMap());var m=Object.create(null);try{var o=JSON.parse(s);Object.keys(o).forEach(function(k){m[k]=o[k];});}catch(e){}return m;},
        getLoginInfo:function(){var v=__loginGet();return v==null||v===''?null:String(v);},
        putLoginInfo:function(v){return __loginPut(String(v));},
        removeLoginInfo:function(){__loginRemove();},
        getLoginHeader:function(){var v=__loginHeaderGet();return v==null||v===''?null:String(v);},
        getLoginHeaderMap:function(){var v=__loginHeaderGet();if(v==null||v==='')return null;var m=Object.create(null);try{var o=JSON.parse(String(v));Object.keys(o).forEach(function(k){m[k]=o[k];});}catch(e){return null;}return m;},
        putLoginHeader:function(v){__loginHeaderPut(String(v));},
        removeLoginHeader:function(){__loginHeaderRemove();}};
    var book={name:'',author:'',bookUrl:'',tocUrl:'',getVariable:function(){return ''},setVariable:function(){}};
    var chapter={title:'',url:'',index:0};
    var Packages={org:{jsoup:{Jsoup:{parse:function(html){return __jsoupParse(String(html));}}}}};
    var org=Packages.org;
    // Preserve primitive code and url: neither can also be a same-named
    // method without breaking strict comparisons. code()/url() remain unsupported.
    // connect headers model the read-only Kotlin Headers subset; get/post headers
    // are a plain map, not an OkHttp Headers object or a complete Java Map.
    function __response(r,jsoup){
        if(!r){throw new Error('HTTP response unavailable');}
        return {
            url:r.url,
            code:r.code,
            length:r.length,
            statusKnown:r.code !== 0,
            body:function(){return r.body},
            statusCode:function(){return r.code},
            isSuccessful:function(){return r.isSuccessful()},
            header:function(k){return r.header(String(k))},
            headers:function(){
                var fields=r.headers(), copy=Object.create(null);
                Object.keys(fields).forEach(function(k){copy[k]=fields[k]});
                if(jsoup){return copy;}
                return {
                    get:function(k){
                        k=String(k).toLowerCase();
                        var names=Object.keys(copy);
                        for(var i=0;i<names.length;i++){
                            if(names[i].toLowerCase()===k){return copy[names[i]];}
                        }
                        return null;
                    },
                    names:function(){return Object.keys(copy)}
                };
            },
            toString:function(){return r.body},
            valueOf:function(){return r.body}
        };
    }
    java.connect=function(u){return __response(java.connectNative(String(u)))};
    java.ajaxAll=function(arr){var o=[];for(var i=0;i<arr.length;i++){o.push(__response(java.connectNative(String(arr[i]))));}return o;};
    java.startBrowserAwait=function(u,t){return java.connect(String(u))};
    java.startBrowser=function(u,t){if(typeof __openBrowser==='function'){__openBrowser(String(u),String(t||''));}return ''};
    java.webView=function(h,u,js){return java.ajax(String(u))};
    var __localRuleVars=Object.create(null);
    java.put=function(k,v){
        k=String(k);v=String(v);
        if(typeof __contextPut==='function'){return __contextPut(k,v);}
        __localRuleVars[k]=v;return v;
    };
    java.get=function(k,h){
        if(arguments.length===1){
            k=String(k);
            if(typeof __contextGet==='function'){return String(__contextGet(k));}
            return Object.prototype.hasOwnProperty.call(__localRuleVars,k)?__localRuleVars[k]:'';
        }
        return __response(java.httpGetNative(String(k),JSON.stringify(h||{})),true);
    };
    java.post=function(u,b,h){return __response(java.httpPostNative(String(u),String(b),JSON.stringify(h||{})),true)};
    java.getCookie=function(u,k){
        if(arguments.length>1 && k!=null){return cookie.getKey(String(u),String(k));}
        return cookie.getCookie(String(u));
    };
    java.getString=function(r,c){
        if(arguments.length>1){return String(__ruleGetStringFrom(String(r),c));}
        return String(__ruleGetString(String(r)));
    };
    java.getStringList=function(r){var s=java.getString(r);return s?s.split('\\n'):[]};
    java.getElement=function(r){return (typeof __ruleGetElements==='function')?__ruleGetElements(String(r))[0]:null};
    java.getElements=function(r){return (typeof __ruleGetElements==='function')?__ruleGetElements(String(r)):[]};
    java.setContent=function(c){__ruleSetContent(c);result=c};
    // ---- crypto / codec (Hutool-compatible subset); byte arrays are signed ints like Java ----
    function __bytes(v,charsetHint){
        if(v==null){return null;}
        if(typeof v==='string'){return JSON.parse(__strToBytes(v,charsetHint||'UTF-8'));}
        if(Array.isArray(v)||(typeof v.length==='number'&&typeof v!=='function')){
            var a=[];for(var i=0;i<v.length;i++){a.push(Number(v[i]));}return a;
        }
        throw new TypeError('Expected a string or byte array');
    }
    function __cryptoKey(v){return typeof v==='string'?JSON.stringify(__bytes(v)):JSON.stringify(__bytes(v));}
    java.strToBytes=function(s,cs){return JSON.parse(__strToBytes(String(s),cs==null?'UTF-8':String(cs)));};
    java.bytesToStr=function(b,cs){return String(__bytesToStr(JSON.stringify(__bytes(b)),cs==null?'UTF-8':String(cs)));};
    java.base64DecodeToByteArray=function(s){
        if(s==null||String(s).trim()===''){return null;}
        var r=__base64ToBytes(String(s));if(r==null){return null;}return JSON.parse(r);
    };
    java.hexDecodeToByteArray=function(s){return JSON.parse(__hexToBytes(String(s)));};
    java.digestHex=function(d,a){return String(__digest(String(d),String(a),'hex'));};
    java.digestBase64Str=function(d,a){return String(__digest(String(d),String(a),'base64'));};
    java.HMacHex=function(d,a,k){return String(__hmac(String(d),String(a),String(k),'hex'));};
    java.HMacBase64=function(d,a,k){return String(__hmac(String(d),String(a),String(k),'base64'));};
    java.createSymmetricCrypto=function(transformation,key,iv){
        var t=String(transformation);
        var kb=JSON.stringify(__bytes(key));
        var ib=(iv==null)?'':JSON.stringify(__bytes(iv));
        var id=__cipherCreate(t,kb,ib);
        return {
            decrypt:function(d){return JSON.parse(__cipherRun(id,'decrypt',typeof d==='string'?'s':'b',typeof d==='string'?d:JSON.stringify(__bytes(d))));},
            decryptStr:function(d){return String(__cipherRun(id,'decryptStr',typeof d==='string'?'s':'b',typeof d==='string'?d:JSON.stringify(__bytes(d))));},
            encrypt:function(d){return JSON.parse(__cipherRun(id,'encrypt',typeof d==='string'?'s':'b',typeof d==='string'?d:JSON.stringify(__bytes(d))));},
            encryptBase64:function(d){return String(__cipherRun(id,'encryptBase64',typeof d==='string'?'s':'b',typeof d==='string'?d:JSON.stringify(__bytes(d))));},
            encryptHex:function(d){return String(__cipherRun(id,'encryptHex',typeof d==='string'?'s':'b',typeof d==='string'?d:JSON.stringify(__bytes(d))));}
        };
    };
    java.androidId=function(){return String(__deviceId());};
    java.deviceID=function(){return String(__deviceId());};
    java.utf8ToGbk=function(s){return s};
    java.t2s=function(s){return s};java.s2t=function(s){return s};
    java.randomUUID=function(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,function(c){var r=Math.random()*16|0;return (c=='x'?r:(r&3|8)).toString(16)})};
    """

    /// Use the injected session's storage; never fall back to the global jar.
    private func installCookieBindings(_ ctx: JSContext) {
        let store = SourceCookieStore(storage: session.configuration.httpCookieStorage)
        func report(_ error: Error) {
            // Never put cookie values or raw input into exceptions or logs.
            let message: String
            switch error as? SourceCookieStore.StoreError {
            case .invalidURL?: message = "Invalid Cookie URL"
            case .invalidCookie?: message = "Invalid Cookie input"
            case .unavailableStorage?: message = "Cookie storage is unavailable"
            case .storageRejected?: message = "Cookie storage rejected the update"
            default: message = "Cookie operation failed"
            }
            guard let current = JSContext.current() else { return }
            let exception = JSValue(newErrorFromMessage: message, in: current)
            exception?.setObject("CookieError", forKeyedSubscript: "name" as NSString)
            current.exception = exception
        }
        let get: @convention(block) (String) -> String = { url in
            store.getCookie(url)
        }
        let getKey: @convention(block) (String, String) -> String = { url, key in
            store.getKey(url, key)
        }
        let set: @convention(block) (String, String) -> Bool = { url, value in
            do { try store.setCookie(url, value); return true }
            catch { report(error); return false }
        }
        let replace: @convention(block) (String, String) -> Bool = { url, value in
            do { try store.replaceCookie(url, value); return true }
            catch { report(error); return false }
        }
        let remove: @convention(block) (String) -> Bool = { url in
            do { try store.removeCookie(url); return true }
            catch { report(error); return false }
        }
        let toMap: @convention(block) (String) -> String = { value in
            do {
                let map = try SourceCookieStore.cookieToMap(value)
                let data = try JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
                return String(data: data, encoding: .utf8) ?? "{}"
            } catch { report(error); return "{}" }
        }
        let fromMap: @convention(block) (String) -> String = { json in
            do {
                guard let data = json.data(using: .utf8),
                      let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                    throw SourceCookieStore.StoreError.invalidCookie
                }
                return try SourceCookieStore.mapToCookie(map)
            } catch { report(error); return "" }
        }
        ctx.setObject(get, forKeyedSubscript: "__cookieGet" as NSString)
        ctx.setObject(getKey, forKeyedSubscript: "__cookieGetKey" as NSString)
        ctx.setObject(set, forKeyedSubscript: "__cookieSet" as NSString)
        ctx.setObject(replace, forKeyedSubscript: "__cookieReplace" as NSString)
        ctx.setObject(remove, forKeyedSubscript: "__cookieRemove" as NSString)
        ctx.setObject(toMap, forKeyedSubscript: "__cookieToMap" as NSString)
        ctx.setObject(fromMap, forKeyedSubscript: "__cookieFromMap" as NSString)
    }

    /// Login values never go to logs or exception text.
    private func installLoginBindings(_ ctx: JSContext, source: BookSource?) {
        let store = JSEngine.loginStore
        let key = source?.bookSourceUrl ?? ""
        let ui = source?.loginUi
        let usable = !key.isEmpty
        func fail(_ message: String) {
            guard let current = JSContext.current() else { return }
            current.exception = JSValue(newErrorFromMessage: message, in: current)
        }
        let map: @convention(block) () -> String = {
            guard usable else { return "{}" }
            let m = store.getLoginInfoMap(key, loginUiJSON: ui)
            guard let d = try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]) else { return "{}" }
            return String(data: d, encoding: .utf8) ?? "{}"
        }
        let get: @convention(block) () -> String = { usable ? (store.getLoginInfo(key) ?? "") : "" }
        let put: @convention(block) (String) -> Bool = { usable ? store.putLoginInfo(key, $0) : false }
        let remove: @convention(block) () -> Void = { if usable { store.removeLoginInfo(key) } }
        let hGet: @convention(block) () -> String = { usable ? (store.getLoginHeader(key) ?? "") : "" }
        let hPut: @convention(block) (String) -> Void = { v in
            guard usable else { return }
            do { try store.putLoginHeader(key, v) } catch { fail("Login header update failed") }
        }
        let hRemove: @convention(block) () -> Void = {
            guard usable else { return }
            do { try store.removeLoginHeader(key) } catch { fail("Login header removal failed") }
        }
        ctx.setObject(map, forKeyedSubscript: "__loginInfoMap" as NSString)
        ctx.setObject(get, forKeyedSubscript: "__loginGet" as NSString)
        ctx.setObject(put, forKeyedSubscript: "__loginPut" as NSString)
        ctx.setObject(remove, forKeyedSubscript: "__loginRemove" as NSString)
        ctx.setObject(hGet, forKeyedSubscript: "__loginHeaderGet" as NSString)
        ctx.setObject(hPut, forKeyedSubscript: "__loginHeaderPut" as NSString)
        ctx.setObject(hRemove, forKeyedSubscript: "__loginHeaderRemove" as NSString)
    }

    /// Crypto errors are thrown as CryptoError with a fixed message; inputs never appear in them.
    private func installCryptoBindings(_ ctx: JSContext) {
        func fail(_ message: String) {
            guard let current = JSContext.current() else { return }
            let e = JSValue(newErrorFromMessage: message, in: current)
            e?.setObject("CryptoError", forKeyedSubscript: "name" as NSString)
            current.exception = e
        }
        func describe(_ error: Error) -> String {
            switch error as? SourceCrypto.CryptoError {
            case .unsupportedTransformation?: return "Unsupported cipher transformation"
            case .invalidKeyLength?: return "Invalid key length"
            case .invalidIVLength?: return "Invalid IV length"
            case .invalidInput?: return "Invalid crypto input"
            case .unsupportedDigest?: return "Unsupported digest algorithm"
            default: return "Crypto operation failed"
            }
        }
        func parseBytes(_ json: String) throws -> Data {
            guard let d = json.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: d) as? [NSNumber] else {
                throw SourceCrypto.CryptoError.invalidInput
            }
            return try SourceCrypto.fromSigned(arr.map { $0.intValue })
        }
        func bytesJSON(_ data: Data) -> String {
            let arr = SourceCrypto.toSigned(data)
            guard let d = try? JSONSerialization.data(withJSONObject: arr),
                  let s = String(data: d, encoding: .utf8) else { return "[]" }
            return s
        }
        func encoding(_ name: String) -> String.Encoding? {
            switch name.uppercased().replacingOccurrences(of: "-", with: "") {
            case "UTF8": return .utf8
            case "UTF16": return .utf16
            case "ISO88591", "LATIN1": return .isoLatin1
            case "ASCII", "USASCII": return .ascii
            case "GBK", "GB2312", "GB18030":
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            default: return nil
            }
        }
        let strToBytes: @convention(block) (String, String) -> String = { s, cs in
            guard let enc = encoding(cs), let data = s.data(using: enc) else {
                fail("Unsupported charset"); return "[]"
            }
            return bytesJSON(data)
        }
        let bytesToStr: @convention(block) (String, String) -> String = { json, cs in
            do {
                guard let enc = encoding(cs) else { throw SourceCrypto.CryptoError.invalidInput }
                return String(data: try parseBytes(json), encoding: enc) ?? ""
            } catch { fail(describe(error)); return "" }
        }
        let base64ToBytes: @convention(block) (String) -> String? = { s in
            guard let d = SourceCrypto.base64Decode(s) else { return nil }
            return bytesJSON(d)
        }
        let hexToBytes: @convention(block) (String) -> String = { s in
            do { return bytesJSON(try SourceCrypto.hexDecode(s)) }
            catch { fail(describe(error)); return "[]" }
        }
        let digest: @convention(block) (String, String, String) -> String = { d, alg, fmt in
            do {
                return fmt == "hex" ? try SourceCrypto.digestHex(d, algorithm: alg)
                                    : try SourceCrypto.digestBase64(d, algorithm: alg)
            } catch { fail(describe(error)); return "" }
        }
        let hmac: @convention(block) (String, String, String, String) -> String = { d, alg, key, fmt in
            do {
                return fmt == "hex" ? try SourceCrypto.hmacHex(d, algorithm: alg, key: key)
                                    : try SourceCrypto.hmacBase64(d, algorithm: alg, key: key)
            } catch { fail(describe(error)); return "" }
        }
        // Ciphers live only as long as this JSContext.
        var ciphers: [Int: SourceCrypto.Cipher] = [:]
        var nextId = 1
        let create: @convention(block) (String, String, String) -> Int = { t, keyJSON, ivJSON in
            do {
                let key = try parseBytes(keyJSON)
                let iv: Data? = ivJSON.isEmpty ? nil : try parseBytes(ivJSON)
                let id = nextId; nextId += 1
                ciphers[id] = try SourceCrypto.Cipher(transformation: t, key: key, iv: iv)
                return id
            } catch { fail(describe(error)); return 0 }
        }
        let run: @convention(block) (Int, String, String, String) -> String = { id, op, kind, payload in
            guard let c = ciphers[id] else { fail("Invalid cipher"); return "" }
            do {
                let isString = kind == "s"
                switch op {
                case "decrypt":
                    let plain = isString ? try c.decryptInput(payload) : try c.decrypt(try parseBytes(payload))
                    return bytesJSON(plain)
                case "decryptStr":
                    if isString { return try c.decryptStr(payload) }
                    guard let s = String(data: try c.decrypt(try parseBytes(payload)), encoding: .utf8) else {
                        throw SourceCrypto.CryptoError.invalidInput
                    }
                    return s
                case "encrypt":
                    return bytesJSON(try c.encrypt(isString ? Data(payload.utf8) : try parseBytes(payload)))
                case "encryptBase64":
                    return try c.encrypt(isString ? Data(payload.utf8) : try parseBytes(payload)).base64EncodedString()
                case "encryptHex":
                    return SourceCrypto.hexEncode(try c.encrypt(isString ? Data(payload.utf8) : try parseBytes(payload)))
                default: throw SourceCrypto.CryptoError.invalidInput
                }
            } catch { fail(describe(error)); return "" }
        }
        // iOS has no ANDROID_ID. A stable per-install identifier plays the same role.
        let deviceId: @convention(block) () -> String = { JSEngine.installIdentifier }
        ctx.setObject(strToBytes, forKeyedSubscript: "__strToBytes" as NSString)
        ctx.setObject(bytesToStr, forKeyedSubscript: "__bytesToStr" as NSString)
        ctx.setObject(base64ToBytes, forKeyedSubscript: "__base64ToBytes" as NSString)
        ctx.setObject(hexToBytes, forKeyedSubscript: "__hexToBytes" as NSString)
        ctx.setObject(digest, forKeyedSubscript: "__digest" as NSString)
        ctx.setObject(hmac, forKeyedSubscript: "__hmac" as NSString)
        ctx.setObject(create, forKeyedSubscript: "__cipherCreate" as NSString)
        ctx.setObject(run, forKeyedSubscript: "__cipherRun" as NSString)
        ctx.setObject(deviceId, forKeyedSubscript: "__deviceId" as NSString)
    }

    /// Stable 16-hex-digit identifier, generated once per app install and kept in UserDefaults.
    /// Same shape as Android's ANDROID_ID; not tied to any hardware or account.
    static var installIdentifier: String {
        let key = "SourceInstallIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key), existing.count == 16 { return existing }
        let fresh = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private func makeContext(_ context: RuleContext? = nil) -> JSContext {
        let ctx = JSContext()!
        installCookieBindings(ctx)
        installCryptoBindings(ctx)
        installLoginBindings(ctx, source: context?.source ?? JSEngine.currentSource)
        ctx.exceptionHandler = { _, e in
            let message = e?.toString() ?? "未知脚本异常"
            print("[JS error] \(message)")
            DebugLog.add("JS 错误：\(String(message.prefix(240)))")
        }
        ctx.setObject(JavaBridge(context: context, session: session,
                                 responseTimeout: responseTimeout),
                      forKeyedSubscript: "java" as NSString)
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
        let effectiveContext = context ?? rule?.context
        let ctx = makeContext(effectiveContext)
        if let c = effectiveContext {
            let put: @convention(block) (String, String) -> String = { c.put($0, $1) }
            let get: @convention(block) (String) -> String = { c.get($0) }
            ctx.setObject(put, forKeyedSubscript: "__contextPut" as NSString)
            ctx.setObject(get, forKeyedSubscript: "__contextGet" as NSString)
        }
        // Query state belongs to this eval only; never mutate the supplied analyzer.
        let r = rule ?? AnalyzeRule(content: JSNodeBridge.unwrap(result ?? ""),
                                    baseUrl: baseUrl ?? "", jsLib: jsLib,
                                    context: effectiveContext ?? RuleContext())
        var input: Any = JSNodeBridge.unwrap(ruleInput ?? r.content)
        func queryInput(_ value: JSValue) -> Any {
            // Explicit null/undefined means empty content, not the current document.
            if value.isNull || value.isUndefined {
                return AnalyzeRule.parse("", baseUrl: r.baseUrl)
            }
            let native = JSNodeBridge.unwrap(value.toObject() ?? "")
            if let html = native as? String {
                return AnalyzeRule.parse(html, baseUrl: r.baseUrl)
            }
            return native
        }
        let gs: @convention(block) (String) -> String = { s in
            r.getString(s, from: input)
        }
        let gsFrom: @convention(block) (String, JSValue) -> String = { s, value in
            r.getString(s, from: queryInput(value))
        }
        let setContent: @convention(block) (JSValue) -> Void = { value in
            input = queryInput(value)
        }
        let ge: @convention(block) (String) -> [Any] = { s in
            r.getElements(s, from: input).map { value in
                if let element = value as? Element { return JSNodeBridge(element) }
                if let list = value as? [Element] { return JSNodeListBridge(list) }
                return AnalyzeRule.jsValue(value)
            }
        }
        let parseHTML: @convention(block) (String) -> JSNodeBridge? = { html in
            guard let document = try? SwiftSoup.parse(html, r.baseUrl) else { return nil }
            return JSNodeBridge(document)
        }
        ctx.setObject(gs, forKeyedSubscript: "__ruleGetString" as NSString)
        ctx.setObject(gsFrom, forKeyedSubscript: "__ruleGetStringFrom" as NSString)
        ctx.setObject(setContent, forKeyedSubscript: "__ruleSetContent" as NSString)
        ctx.setObject(ge, forKeyedSubscript: "__ruleGetElements" as NSString)
        ctx.setObject(parseHTML, forKeyedSubscript: "__jsoupParse" as NSString)
        ctx.setObject(result ?? "", forKeyedSubscript: "result" as NSString)
        ctx.setObject(baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(result ?? "", forKeyedSubscript: "src" as NSString)
        for (k, v) in vars { ctx.setObject(v, forKeyedSubscript: k as NSString) }
        if let lib = jsLib, !lib.isEmpty, !lib.hasPrefix("{") { ctx.evaluateScript(lib) }
        guard let v = ctx.evaluateScript(script), !v.isUndefined, !v.isNull else { return nil }
        if v.isString || v.isNumber || v.isBoolean { return v.toString() }
        if v.isArray { return JSNodeBridge.unwrap(v.toArray() ?? []) }
        if let object = v.toObject() { return JSNodeBridge.unwrap(object) }
        return v.toString()
    }

    func evalString(_ script: String, result: Any? = nil, baseUrl: String? = nil,
                    vars: [String: Any] = [:], jsLib: String? = nil,
                    context: RuleContext? = nil) -> String? {
        guard let v = eval(script, result: result, baseUrl: baseUrl, vars: vars, jsLib: jsLib, context: context) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: "\n") }
        if JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) {
            return String(data: d, encoding: .utf8)
        }
        return "\(v)"
    }

    /// 在书源上下文里执行一段 JS（登录按钮、login() 等），返回字符串结果；脚本抛错时返回 .failure。
    /// 脚本 = loginUrl 里的函数库 + 调用语句。toast 通过 ToastCenter 出口。
    func runLoginScript(source: BookSource, library: String?, call: String) -> Result<String, LoginScriptError> {
        let context = RuleContext(source: source)
        let ctx = makeContext(context)
        let openBrowser: @convention(block) (String, String) -> Void = { ToastCenter.openBrowser($0, $1) }
        ctx.setObject(openBrowser, forKeyedSubscript: "__openBrowser" as NSString)
        var thrown: String?
        ctx.exceptionHandler = { _, value in thrown = value?.toString() ?? "脚本错误" }
        if let lib = source.jsLib, !lib.isEmpty, !lib.hasPrefix("{") { ctx.evaluateScript(lib) }
        if let l = library, !l.isEmpty { ctx.evaluateScript(l) }
        let value = ctx.evaluateScript(call)
        if let t = thrown { return .failure(LoginScriptError(message: t)) }
        guard let v = value, !v.isUndefined, !v.isNull else { return .success("") }
        return .success(v.toString() ?? "")
    }
}

struct LoginScriptError: Error { let message: String }
