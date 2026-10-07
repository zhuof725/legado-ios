import SwiftUI
import WebKit

extension URL: Identifiable { public var id: String { absoluteString } }

/// 段评/章评：用 WebView 打开书源给的评论页（半屏，默认约 80% 屏高，可拖到全屏）。
/// 去掉导航栏标题，只保留一个小的「关闭」，让评论页自己的顶栏贴近半屏顶部，与书源在 Android 上的半屏一致。
struct CommentSheet: View {
    let url: URL
    var heightFraction: CGFloat = 0.6

    var body: some View {
        // 不放额外按钮：下拉或点半屏外侧即可关闭。
        CommentWebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .presentationDetents([.fraction(heightFraction), .large])
            .presentationDragIndicator(.visible)
            .modifier(SheetCorner(radius: 20))
    }
}

/// presentationCornerRadius 需要 iOS 16.4；低版本保持系统默认圆角。
private struct SheetCorner: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) { content.presentationCornerRadius(radius) } else { content }
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


/// 段尾评论气泡：空心圆角气泡 + 内部数字，画成 UIImage，用 Text(Image) 接在段落文字后面。
/// 图片的底边对齐文字基线（imageBaseline 由 Text 的 baselineOffset 抵消尾巴），高度不超过一行字高，
/// 这样既不顶到上一行，也不压到下一行。
enum CommentBubble {
    private static var cache: [String: UIImage] = [:]

    /// 气泡主体高度约为字号的 1.05 倍；尾巴向下伸出，用负的基线偏移补回。
    static func tailHeight(for size: CGFloat) -> CGFloat { size * 0.22 }

    static func image(count: Int, size: CGFloat, color: UIColor) -> UIImage {
        let label = count > 99 ? "99" : String(count)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "\(label)|\(Int(size))|\(Int(r * 255)),\(Int(g * 255)),\(Int(b * 255))"
        if let hit = cache[key] { return hit }
        let w = size * (label.count > 1 ? 1.55 : 1.25), h = size * 1.0
        let tail = tailHeight(for: size)
        let canvas = CGSize(width: w + 2, height: h + tail + 2)
        let img = UIGraphicsImageRenderer(size: canvas).image { _ in
            let line = max(size * 0.085, 1)
            let body = CGRect(x: 1 + line / 2, y: 1 + line / 2, width: w - line, height: h - line)
            let path = UIBezierPath(roundedRect: body, cornerRadius: body.height / 2)
            path.move(to: CGPoint(x: body.minX + body.width * 0.24, y: body.maxY - 1))
            path.addLine(to: CGPoint(x: body.minX + body.width * 0.12, y: body.maxY + tail))
            path.addLine(to: CGPoint(x: body.minX + body.width * 0.46, y: body.maxY - 1))
            color.setStroke()
            path.lineWidth = line
            path.stroke()
            let font = UIFont.systemFont(ofSize: size * 0.58, weight: .semibold)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let ts = text.size()
            text.draw(at: CGPoint(x: body.midX - ts.width / 2, y: body.midY - ts.height / 2))
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = img
        return img
    }
}
