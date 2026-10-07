import Foundation

/// 教程「URL必知必会」中的 {"webView":true} 与 ruleContent.webJs：
/// 用 WKWebView 加载网页、执行 JS 后取源码；遇到 Cloudflare 等人机验证时，
/// 先在后台等待自动通过，不行再弹出网页让用户手动验证，并把 Cookie 同步给 URLSession。
enum WebViewSupport {
    /// 与 WebView 保持一致的 UA，cf_clearance 等 Cookie 与 UA 绑定
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// 判断返回内容是否是人机验证页
    static func isChallenge(_ html: String) -> Bool {
        let head = String(html.prefix(6000))
        let marks = ["<title>Just a moment", "challenges.cloudflare.com", "cf-browser-verification",
                     "__gatekeeper_challenge", "_cf_chl_opt", "<title>Redirecting...", "Attention Required! | Cloudflare",
                     "TCaptcha.js", "__captcha", "WafCaptcha", "captcha.qq.com"]
        return marks.contains { head.contains($0) }
    }
}

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class WebViewLoader: NSObject, WKNavigationDelegate {
    /// 由 UI 层设置：需要用户手动验证时调用，返回验证后的网页源码
    static var interactiveHandler: ((URL) async -> String?)?

    private let webView: WKWebView
    private var loadedOnce = false

    private override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: cfg)
        super.init()
        webView.customUserAgent = WebViewSupport.userAgent
        webView.navigationDelegate = self
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.loadedOnce = true }
    }

    /// 加载网页并返回 (源码, 最终URL)。js 为空时返回 document.documentElement.outerHTML
    static func load(url: String, method: String = "GET", body: String? = nil,
                     headers: [String: String] = [:], js: String? = nil,
                     timeout: Double = 25, allowInteractive: Bool = true) async throws -> (String, String) {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        let loader = WebViewLoader()
        await syncCookiesToWebView(for: u)
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers where k.lowercased() != "user-agent" { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body {
            req.httpBody = b.data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first {
            loader.webView.alpha = 0.01
            loader.webView.isUserInteractionEnabled = false
            win.insertSubview(loader.webView, at: 0)
        }
        defer { loader.webView.stopLoading(); loader.webView.removeFromSuperview() }
        loader.webView.load(req)

        let deadline = Date().addingTimeInterval(timeout)
        var html = ""
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 800_000_000)
            if !loader.loadedOnce { continue }
            html = await loader.source(js: nil)
            if !WebViewSupport.isChallenge(html), !html.isEmpty { break }
        }
        var finalUrl = loader.webView.url?.absoluteString ?? url
        if WebViewSupport.isChallenge(html), allowInteractive, let handler = interactiveHandler {
            if let h = await handler(u) { html = h }
            finalUrl = url
        }
        await syncCookiesFromWebView()
        if let js = js, !js.isEmpty, !WebViewSupport.isChallenge(html) {
            let r = await loader.source(js: js)
            if !r.isEmpty { html = r }
        }
        return (html, finalUrl)
    }

    private func source(js: String?) async -> String {
        let script = (js?.isEmpty == false) ? js! : "document.documentElement.outerHTML"
        return await withCheckedContinuation { c in
            webView.evaluateJavaScript(script) { v, _ in
                if let s = v as? String { c.resume(returning: s) }
                else if let v = v { c.resume(returning: "\(v)") }
                else { c.resume(returning: "") }
            }
        }
    }

    // MARK: Cookie 同步

    static func syncCookiesFromWebView() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { c in store.getAllCookies { c.resume(returning: $0) } }
        for ck in cookies { HTTPCookieStorage.shared.setCookie(ck) }
    }

    static func syncCookiesToWebView(for url: URL) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for ck in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.setCookie(ck) { c.resume() } }
        }
    }
}
#endif
