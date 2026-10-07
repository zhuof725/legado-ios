import Foundation

/// Offline URLSession/URLProtocol fixtures, not real-network verification.
/// Integrate from an async runner with:
/// try await HTTPResponseRegression.run(check)
/// No global URLProtocol registration and no changes to JSEngine.shared.
enum HTTPResponseRegression {
    private final class Transport: URLProtocol {
        private static let lock = NSLock()
        private static var stopped: Set<String> = []

        static func wasStopped(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped.contains(path)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, url.host == "http-fixture.invalid" else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let path = url.path
            if path.hasPrefix("/stall/") { return }
            if path == "/offline" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            if path == "/transport-timeout" {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }
            let status = Int(url.lastPathComponent) ?? 200
            // Supply a final URL directly. This checks metadata propagation,
            // not URLSession's redirect handling or any live site's behavior.
            let finalURL = URL(string: "https://http-fixture.invalid/final/\(status)")!
            let response = HTTPURLResponse(url: finalURL, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "X-Fixture": "metadata-\(status)",
                    "X-Method": request.httpMethod ?? "GET"
                ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("body-\(status)".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            Self.lock.lock()
            Self.stopped.insert(request.url?.path ?? "")
            Self.lock.unlock()
        }
    }

    static func run(_ check: (Bool, String) -> Void) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Transport.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let root = "https://http-fixture.invalid"
        let engine = JSEngine(session: session, responseTimeout: 5)

        for status in [200, 404, 500] {
            let response = try await AnalyzeUrl(rawUrl: "\(root)/status/\(status)")
                .fetchResponse(session: session)
            check(response.code == status, "request preserves fixture HTTP \(status)")
            check(response.body == "body-\(status)", "HTTP \(status) body survives")
            check(response.url == "\(root)/final/\(status)", "HTTP \(status) final response URL survives")
            let native = StrResponse(response)
            check(native.header("x-fixture") == "metadata-\(status)"
                  && native.header("X-FIXTURE") == "metadata-\(status)",
                  "HTTP \(status) response headers are case insensitive")
            check(native.isSuccessful() == (status == 200), "HTTP \(status) success classification")
            check(native.url == response.url && native.body == response.body && native.code == status,
                  "native response properties remain compatible")

            // Integration: JS -> JavaBridge -> AnalyzeUrl -> injected URLSession
            // -> URLProtocol -> native response -> production JS wrapper.
            let script = """
            var r = java.connect('\(root)/status/\(status)');
            [r.code === \(status), typeof r.code === 'number',
             r.statusCode() === \(status), r.statusKnown,
             r.isSuccessful() === \(status == 200 ? "true" : "false"),
             r.body() === 'body-\(status)',
             r.url === '\(root)/final/\(status)',
             r.header('x-FiXtUrE') === 'metadata-\(status)',
             r.headers().get('X-FIXTURE') === 'metadata-\(status)',
             r.headers().get('missing') === null,
             r.headers().names().length >= 3].every(function(v){return v;});
            """
            check(engine.evalString(script) == "true",
                  "complete request-to-JS integration preserves HTTP \(status) metadata")
        }

        check(engine.evalString("""
            var a = java.get('\(root)/status/404', {});
            var b = java.post('\(root)/status/500', 'key=value', {});
            function field(r, name) {
                var h=r.headers(), k=Object.keys(h).filter(function(k){
                    return k.toLowerCase()===name;
                })[0];
                return h[k];
            }
            [a.statusCode()===404, b.statusCode()===500,
             a.code===404, b.code===500, !a.isSuccessful(), !b.isSuccessful(),
             field(a,'x-method')==='GET', field(b,'x-method')==='POST',
             field(b,'x-fixture')==='metadata-500',
             typeof a.url==='string', b.body()==='body-500'].every(function(v){return v;});
            """) == "true", "get/post preserve HTTP errors as responses and expose plain header maps")

        for (path, expectedName) in [("offline", "NetworkError"), ("transport-timeout", "TimeoutError")] {
            do {
                _ = try await AnalyzeUrl(rawUrl: "\(root)/\(path)").fetchResponse(session: session)
                check(false, "\(path) must throw instead of returning success")
            } catch {
                let native = error as NSError
                let expected = path == "offline" ? URLError.notConnectedToInternet.rawValue : URLError.timedOut.rawValue
                check(native.domain == NSURLErrorDomain && native.code == expected,
                      "request preserves \(path) transport error")
            }
            for expression in ["java.connect(u)", "java.get(u,{})", "java.post(u,'x=1',{})", "java.ajax(u)", "java.ajaxAll([u])"] {
                let script = """
                (function(){var u='\(root)/\(path)';
                    try { \(expression); return 'false-success'; }
                    catch(e) { return e.name; }
                })();
                """
                check(engine.evalString(script) == expectedName,
                      "\(expression) makes \(path) catchable as \(expectedName)")
            }
        }

        let stallPath = "/stall/" + UUID().uuidString
        let timeoutEngine = JSEngine(session: session, responseTimeout: 1)
        check(timeoutEngine.evalString("""
            (function(){try {
                java.connect('\(root)\(stallPath)'); return 'false-success';
            } catch(e) {return e.name;}})();
            """) == "TimeoutError", "synchronous bridge deadline throws rather than fabricating 200")
        // Bounded polling for the cancellation callback, not an external request.
        for _ in 0..<100 {
            if Transport.wasStopped(stallPath) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(Transport.wasStopped(stallPath), "bridge deadline cancels the underlying URLSession request")
        check(engine.evalString("java.connect('\(root)/status/200').code === 200") == "true",
              "timed-out request cannot replace a subsequent request's result")

        let dataURL = "data:application/octet-stream;base64,QQ=="
        let unknown = try await AnalyzeUrl(rawUrl: dataURL).fetchResponse(session: session)
        check(unknown.code == 0 && unknown.headers.isEmpty && unknown.body == "41",
              "non-HTTP response explicitly has unknown status")
        check(engine.evalString("""
            var r=java.connect('\(dataURL)');
            r.code===0 && !r.statusKnown && !r.isSuccessful() && r.statusCode()===0;
            """) == "true", "unknown status is not JS HTTP success")
        let tuple = try await AnalyzeUrl(rawUrl: dataURL).fetch()
        check(tuple.0 == unknown.body && tuple.1 == unknown.url,
              "legacy fetch retains body/URL tuple behavior")
    }
}
