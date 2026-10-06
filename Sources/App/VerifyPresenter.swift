import UIKit
import WebKit

/// 书源遇到人机验证（Cloudflare 等）时，弹出网页让用户手动通过验证。
/// 用户点「完成」后读取网页源码返回，并把 Cookie 同步给 URLSession。
@MainActor
enum VerifyPresenter {
    private static var busy = false

    static func install() {
        WebViewLoader.interactiveHandler = { url in await present(url) }
    }

    static func present(_ url: URL) async -> String? {
        if busy { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let win = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first,
              let root = win.rootViewController else { return nil }
        var top = root
        while let p = top.presentedViewController { top = p }
        busy = true
        defer { busy = false }
        return await withCheckedContinuation { c in
            let vc = VerifyViewController(url: url) { html in c.resume(returning: html) }
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .fullScreen
            top.present(nav, animated: true)
        }
    }
}

final class VerifyViewController: UIViewController {
    private let url: URL
    private let onFinish: (String?) -> Void
    private var finished = false
    private lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.customUserAgent = WebViewSupport.userAgent
        return w
    }()

    init(url: URL, onFinish: @escaping (String?) -> Void) {
        self.url = url
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
        view.addSubview(webView)
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))
        navigationItem.prompt = "按网页提示完成验证，看到正常页面后点「完成」"
        webView.load(URLRequest(url: url))
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
