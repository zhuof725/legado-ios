import Foundation

/// Synthetic, instance-local URLProtocol fixtures. Never uses the shared cookie jar.
enum CookieBridgeRegression {
    private final class Transport: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url, url.host?.hasSuffix(".invalid") == true else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            // Return only a Boolean outcome, never echo cookie contents into logs.
            let raw = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let fields = (try? SourceCookieStore.cookieToMap(raw)) ?? [:]
            let matched = fields["transport"] == "fixture"
            let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data((matched ? "matched" : "absent").utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        func configuration() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [Transport.self]
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            return config
        }
        let configA = configuration()
        let configB = configuration()
        guard let jarA = configA.httpCookieStorage, let jarB = configB.httpCookieStorage else {
            check(false, "Cookie bridge fixtures require private ephemeral storage")
            return
        }
        guard jarA !== jarB else {
            check(false, "Cookie bridge fixtures must not share storage")
            return
        }
        let sessionA = URLSession(configuration: configA)
        let sessionB = URLSession(configuration: configB)
        let noStorageConfig = configuration()
        noStorageConfig.httpCookieStorage = nil
        let noStorageSession = URLSession(configuration: noStorageConfig)
        defer {
            sessionA.invalidateAndCancel()
            sessionB.invalidateAndCancel()
            noStorageSession.invalidateAndCancel()
        }
        let host = "bridge-" + UUID().uuidString.lowercased() + ".invalid"
        let root = "https://" + host
        let sibling = "https://other-" + host
        defer {
            for jar in [jarA, jarB] {
                for item in jar.cookies ?? [] where item.domain == host || item.domain == "other-" + host {
                    jar.deleteCookie(item)
                }
            }
        }
        let engineA = JSEngine(session: sessionA, responseTimeout: 5)
        let engineB = JSEngine(session: sessionB, responseTimeout: 5)
        let absent = JSEngine(session: noStorageSession, responseTimeout: 5)
        func run(_ script: String, _ engine: JSEngine) -> String? {
            engine.evalString(script, vars: ["cookieURL": root, "otherURL": sibling])
        }

        check(run("""
            cookie.setCookie(cookieURL,'first=one; stale=two');
            cookie.replaceCookie(cookieURL,'first=three; token=x=y==; empty=');
            cookie.getKey(cookieURL,'first')==='three' &&
            cookie.getKey(cookieURL,'stale')==='two' &&
            java.getCookie(cookieURL,'token')==='x=y==' &&
            java.getCookie(cookieURL)===cookie.getCookie(cookieURL) &&
            java.getCookie(cookieURL,null)===cookie.getCookie(cookieURL) &&
            cookie.cookieToMap(cookie.getCookie(cookieURL)).empty==='';
            """, engineA) == "true", "production Cookie bridge set replace and read overloads")
        check(run("cookie.getKey(cookieURL,'first')", engineA) == "three",
              "Cookie state survives separate JS evaluations in the same session")
        check(run("cookie.getCookie(cookieURL)", engineB) == "",
              "separate injected sessions do not share Cookie state")
        check(run("cookie.getCookie(otherURL)", engineA) == "",
              "Cookie bridge does not leak into another host")
        check(run("cookie.getCookie(cookieURL.replace('https:','http:'))", engineA) == "",
              "Cookie bridge respects Secure when reading HTTP URLs")

        check(run("""
            var m=cookie.cookieToMap('__proto__=safe; constructor=value; token=x=y==');
            Object.getPrototypeOf(m)===null && m.__proto__==='safe' &&
            m.constructor==='value' && m.token==='x=y==' &&
            cookie.mapToCookie({z:'2',a:'1'})==='a=1; z=2' &&
            cookie.mapToCookie({})===null && cookie.mapToCookie(null)===null;
            """, engineA) == "true", "Cookie map conversion preserves special keys without prototype mutation")
        check(run("""
            (function(){try {cookie.mapToCookie({bad:42});return false;}
            catch(e){return e.name==='TypeError';}})();
            """, engineA) == "true", "Cookie map rejects non-string values explicitly")
        check(run("""
            (function(){var before=cookie.getCookie(cookieURL);
            try {cookie.setCookie(cookieURL,'valid=value; broken');return false;}
            catch(e){return e.name==='CookieError' && cookie.getCookie(cookieURL)===before;}})();
            """, engineA) == "true", "invalid Cookie input throws without partially replacing stored values")
        check(engineA.evalString("""
            (function(){try {cookie.setCookie(cookieURL,badInput);return false;}
            catch(e){return e.name==='CookieError' && e.message.indexOf('private-marker')<0;}})();
            """, vars: ["cookieURL": root, "badInput": "x=private-marker\r\ninjected=yes"]) == "true",
              "Cookie bridge rejects header injection without exposing input in its error")

        check(run("cookie.getCookie(cookieURL)", absent) == "",
              "session without storage reads empty without global fallback")
        for call in ["cookie.setCookie(cookieURL,'x=y')", "cookie.replaceCookie(cookieURL,'x=y')", "cookie.removeCookie(cookieURL)"] {
            check(run("(function(){try {\(call);return false;}catch(e){return e.name==='CookieError';}})();", absent) == "true",
                  "missing Cookie storage mutation throws a catchable error")
        }
        check(run("cookie.getKey(cookieURL,'first')", engineA) == "three",
              "missing-storage operations do not mutate another session")

        check(run("cookie.setCookie(cookieURL,'transport=fixture'); java.connect(cookieURL+'/echo').body()", engineA) == "matched",
              "JS Cookie write reaches the injected URLSession request through production HTTP bridge")
        check(run("java.connect(cookieURL+'/echo').body()", engineB) == "absent",
              "another session sends no Cookie from the first session")
        check(run("""
            cookie.setCookie(otherURL,'other=kept');
            cookie.removeCookie(cookieURL);
            cookie.getCookie(cookieURL)==='' && cookie.getKey(otherURL,'other')==='kept';
            """, engineA) == "true", "Cookie removal preserves another host")
        check(run("java.connect(cookieURL+'/echo').body()", engineA) == "absent",
              "removed Cookie no longer accompanies the session request")
    }
}
