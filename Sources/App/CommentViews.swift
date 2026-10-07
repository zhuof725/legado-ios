import SwiftUI
import WebKit

extension URL: Identifiable { public var id: String { absoluteString } }

/// 段评/章评：用 WebView 打开书源给的评论页（半屏）。评论页本身由书源服务提供。
struct CommentSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CommentWebView(url: url)
                .navigationTitle("评论")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct CommentWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.customUserAgent = WebViewSupport.userAgent
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// 正文里的图片块：支持 data: URI（SVG 章评气泡、图片）与网络图片。
struct ContentImageView: View {
    let src: String
    @State private var image: UIImage?
    @State private var svgHTML: String?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity)
            } else if let html = svgHTML {
                SVGWebView(html: html).frame(height: 120)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task { await load() }
    }

    private func load() async {
        if src.hasPrefix("data:") {
            guard let comma = src.firstIndex(of: ",") else { return }
            let meta = src[..<comma].lowercased()
            let payload = String(src[src.index(after: comma)...])
            let data: Data?
            if meta.contains(";base64") {
                var p = payload.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
                while p.count % 4 != 0 { p += "=" }
                data = Data(base64Encoded: p)
            } else { data = payload.removingPercentEncoding?.data(using: .utf8) }
            guard let d = data else { return }
            if meta.contains("svg") {
                svgHTML = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0;background:transparent}svg{width:100%;height:auto}</style></head><body>" + (String(data: d, encoding: .utf8) ?? "") + "</body></html>"
            } else { image = UIImage(data: d) }
        } else if let u = URL(string: src), let (d, _) = try? await URLSession.shared.data(from: u) {
            image = UIImage(data: d)
        }
    }
}

struct SVGWebView: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.isUserInteractionEnabled = false
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { uiView.loadHTMLString(html, baseURL: nil) }
}
