import Foundation

/// Private storage fixtures plus real HTTP loopback wire verification.
/// No shared cookie jar, external server, HTTPS or redirect verification.
enum CookieBridgeRegression {
    // Storage-only fixtures must never accidentally reach the network.
    // A custom URLProtocol's request is not guaranteed to represent Foundation's
    // final HTTP Cookie serialization. Observe wire bytes instead; never fill
    // a Cookie header from storage inside this test protocol.
    private final class Transport: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
        override func stopLoading() {}
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        // The caller's check may exit(1). Report only AFTER fixture defers have
        // closed the listener/connections and invalidated all private sessions.
        var results: [(Bool, String)] = []
        try await runFixtures { results.append(($0, $1)) }
        for (passed, label) in results { check(passed, label) }
    }

    private static func runFixtures(_ check: (Bool, String) -> Void) async throws {
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
            [cookie.setCookie(cookieURL,'side=effect') === undefined,
             cookie.replaceCookie(cookieURL,'other=effect') === undefined,
             cookie.removeCookie(cookieURL) === undefined].every(function(x){return x;});
            """, engineA) == "true", "Cookie mutation APIs return undefined like Kotlin Unit")
        let templateURL = "https://template-" + UUID().uuidString.lowercased() + ".invalid"
        let templateData = try JSONSerialization.data(withJSONObject: [
            "bookSourceUrl": templateURL, "bookSourceName": "URL side-effect regression"
        ])
        let templateSource = try JSONDecoder().decode(BookSource.self, from: templateData)
        let templateContext = RuleContext(source: templateSource)
        // Same shape as the unmodified biquge345 searchUrl. Only removes a unique
        // synthetic host with no credentials; no request is made by AnalyzeUrl.init.
        let sideEffectRequest = AnalyzeUrl(
            rawUrl: "{{cookie.removeCookie(source.getKey())}}\n" + templateURL + "/s.php,{\"method\":\"POST\",\"body\":\"s={{key}}\"}",
            key: "测试", baseUrl: templateURL, context: templateContext)
        check(sideEffectRequest.url == templateURL + "/s.php"
              && sideEffectRequest.method == "POST" && sideEffectRequest.body == "s=测试",
              "biquge345 Cookie removal URL template emits no true prefix")

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

        check(run("""
            cookie.setCookie(otherURL,'other=kept');
            cookie.removeCookie(cookieURL);
            cookie.getCookie(cookieURL)==='' && cookie.getKey(otherURL,'other')==='kept';
            """, engineA) == "true", "Cookie removal preserves another host")
        try await runLoopback(check)
    }

    private static func runLoopback(_ check: (Bool, String) -> Void) async throws {
        func configuration() -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            // Use Foundation's HTTP transport, not a custom URLProtocol.
            config.protocolClasses = []
            config.connectionProxyDictionary = [:]
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 6
            config.waitsForConnectivity = false
            return config
        }
        let configA = configuration()
        let configB = configuration()
        guard let jarA = configA.httpCookieStorage,
              let jarB = configB.httpCookieStorage, jarA !== jarB else {
            check(false, "loopback stage=setup error=PrivateStorageUnavailable")
            return
        }
        let sessionA = URLSession(configuration: configA)
        let sessionB = URLSession(configuration: configB)
        let server = CookieLoopbackServer()
        defer {
            server.stop()
            sessionA.invalidateAndCancel()
            sessionB.invalidateAndCancel()
            // Both jars belong exclusively to this fixture.
            for jar in [jarA, jarB] {
                for cookie in jar.cookies ?? [] { jar.deleteCookie(cookie) }
            }
        }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let root: String
            do {
                root = try server.start()
            } catch let failure as CookieLoopbackServer.Failure {
                try Task.checkCancellation()
                check(false, "loopback stage=start error=\(failure.rawValue)")
                return
            } catch {
                try Task.checkCancellation()
                check(false, "loopback stage=start error=UnexpectedServerError")
                return
            }
            try Task.checkCancellation()
            let engineA = JSEngine(session: sessionA, responseTimeout: 7)
            let engineB = JSEngine(session: sessionB, responseTimeout: 7)

            func evaluate(_ script: String, _ engine: JSEngine) -> String {
                // Catch inside JS; never report exception messages, raw headers,
                // native descriptions or arbitrary response bodies.
                engine.evalString("""
                    (function(){try { \(script) }
                    catch(e){
                        if(e.name==='CookieError') return 'CookieError';
                        if(e.name==='TimeoutError') return 'TimeoutError';
                        if(e.name==='NetworkError') return 'NetworkError';
                        return 'JavaScriptError';
                    }})();
                    """, vars: ["cookieURL": root]) ?? "EvaluationError"
            }
            func errorCategory(_ result: String) -> String {
                switch result {
                case "matched", "absent": return "none"
                case "CookieError", "TimeoutError", "NetworkError",
                     "JavaScriptError", "EvaluationError": return result
                default: return "UnexpectedResponse"
                }
            }
            func observe(_ phase: String, _ expected: Bool,
                         _ result: String, _ label: String) {
                let wire = server.received(phase)
                let bodyMatches = result == (expected ? "matched" : "absent")
                let failure = server.failure
                // Missing wire evidence is a failure, not an absent cookie.
                let passed = wire == expected && bodyMatches && failure == nil
                let category = failure?.rawValue ?? errorCategory(result)
                check(passed, "\(label); stage=\(phase) observed=\(wire != nil) matched=\(wire == true) responseOK=\(bodyMatches) error=\(category)")
            }

            // HTTP origin creates a non-Secure cookie through production JS.
            // Never set a native Cookie header or copy cookies between jars.
            let written = evaluate("""
                cookie.setCookie(cookieURL,'transport=fixture');
                return java.connect(cookieURL+'/write').body();
                """, engineA)
            try Task.checkCancellation()
            observe("/write", true, written,
                    "JS Cookie write reaches the injected URLSession request through production HTTP bridge")

            let isolated = evaluate("return java.connect(cookieURL+'/isolated').body();", engineB)
            try Task.checkCancellation()
            observe("/isolated", false, isolated,
                    "another session sends no Cookie from the first session")

            let removed = evaluate("""
                cookie.removeCookie(cookieURL);
                return java.connect(cookieURL+'/removed').body();
                """, engineA)
            try Task.checkCancellation()
            observe("/removed", false, removed,
                    "removed Cookie no longer accompanies the session request")
        }, onCancel: {
            // Independent of the thread blocked by the synchronous JS bridge.
            sessionA.invalidateAndCancel()
            sessionB.invalidateAndCancel()
            server.stop()
        })
    }
}
