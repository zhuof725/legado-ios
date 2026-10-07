import UIKit
import WebKit

/// 书源遇到人机验证（Cloudflare 等）时，弹出网页让用户手动通过验证。
/// 用户点「完成」后读取网页源码返回，并把 Cookie 同步给 URLSession。
@MainActor
enum VerifyPresenter {
    private static var busy = false

    static func install() {
        WebViewLoader.interactiveHandler = { webView in await present(webView) }
    }

    static func present(_ webView: WKWebView) async -> String? {
        if busy { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first,
              let root = win.rootViewController else { return nil }
        var top = root
        while let p = top.presentedViewController { top = p }
        busy = true
        defer { busy = false }
        return await withCheckedContinuation { c in
            let vc = VerifyViewController(webView: webView) { html in c.resume(returning: html) }
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            top.present(nav, animated: true)
        }
    }
}

final class VerifyViewController: UIViewController {
    private let webView: WKWebView
    private let onFinish: (String?) -> Void
    private var finished = false

    init(webView: WKWebView, onFinish: @escaping (String?) -> Void) {
        self.webView = webView
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "人机验证"
        view.backgroundColor = .systemBackground
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.removeFromSuperview()
        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        view.addSubview(webView)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))
        navigationItem.prompt = "按网页提示完成验证，看到正常页面后点「完成」"
        // 复用 loader 已加载的页面，不重新 load（否则会丢失 POST 和 Cookie 上下文）。
    }

    @objc private func cancelTapped() { finish(nil) }

    @objc private func doneTapped() {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] v, _ in
            let html = v as? String
            Task { @MainActor in
                await WebViewLoader.syncCookiesFromWebView()
                self?.finish(html)
            }
        }
    }

    private func finish(_ html: String?) {
        guard !finished else { return }
        finished = true
        let cb = onFinish
        dismiss(animated: true) { cb(html) }
    }
}
