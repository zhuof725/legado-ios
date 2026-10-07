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


/// 段尾评论气泡：空心圆角气泡 + 内部数字，画成 UIImage，便于用 Text(Image) 接在段落文字后面。
enum CommentBubble {
    private static var cache: [String: UIImage] = [:]

    static func image(count: Int, size: CGFloat, color: UIColor) -> UIImage {
        let label = count > 99 ? "99" : String(count)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "\(label)|\(Int(size))|\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255))"
        if let hit = cache[key] { return hit }
        let w = size * 1.7, h = size * 1.35
        let tail: CGFloat = size * 0.28
        let canvas = CGSize(width: w + 2, height: h + tail + 2)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let img = renderer.image { _ in
            let line = max(size * 0.09, 1)
            let body = CGRect(x: 1 + line / 2, y: 1 + line / 2, width: w - line, height: h - line)
            let path = UIBezierPath(roundedRect: body, cornerRadius: body.height / 2)
            // 左下角的小尾巴
            path.move(to: CGPoint(x: body.minX + body.width * 0.22, y: body.maxY - 1))
            path.addLine(to: CGPoint(x: body.minX + body.width * 0.12, y: body.maxY + tail))
            path.addLine(to: CGPoint(x: body.minX + body.width * 0.42, y: body.maxY - 1))
            color.setStroke()
            path.lineWidth = line
            path.stroke()
            let font = UIFont.systemFont(ofSize: size * 0.62, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let text = NSAttributedString(string: label, attributes: attrs)
            let ts = text.size()
            text.draw(at: CGPoint(x: body.midX - ts.width / 2, y: body.midY - ts.height / 2))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = img
        return img
    }
}
