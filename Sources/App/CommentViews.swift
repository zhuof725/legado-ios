import SwiftUI
import WebKit

extension URL: Identifiable { public var id: String { absoluteString } }

/// 段评/章评：默认半屏，上划可展开到全屏；内容区域优先滚动网页。
struct CommentSheet: View {
    let url: URL
    var heightFraction: CGFloat = 0.6

    var body: some View {
        // 不放额外按钮：下拉或点半屏外侧即可关闭。
        CommentWebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            // 默认半屏；上划可展开到全屏，网页内容仍优先接收滚动。
            .presentationDetents([.fraction(heightFraction), .large])
            .presentationDragIndicator(.visible)
            .modifier(SheetCorner(radius: 20))
    }
}

/// presentationCornerRadius 需要 iOS 16.4；低版本保持系统默认圆角。
private struct SheetCorner: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.presentationCornerRadius(radius).presentationContentInteraction(.scrolls)
        } else {
            content
        }
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


/// 带行内段评气泡的正文段落。使用 UITextView 让气泡参与正常换行，点击命中附件时才打开评论。
struct InlineCommentParagraph: UIViewRepresentable {
    let text: String
    let count: Int
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let color: UIColor
    let continuation: Bool
    let onTextTap: (() -> Void)?
    let onTap: () -> Void

    init(text: String, count: Int, fontSize: CGFloat, lineSpacing: CGFloat,
         color: UIColor, continuation: Bool = false, onTextTap: (() -> Void)? = nil,
         onTap: @escaping () -> Void) {
        self.text = text
        self.count = count
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.color = color
        self.continuation = continuation
        self.onTextTap = onTextTap
        self.onTap = onTap
    }

    func makeUIView(context: Context) -> CommentTextView {
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        view.onBubbleTap = onTap
        view.onTextTap = onTextTap
        view.installTapHandling()
        return view
    }

    func updateUIView(_ view: CommentTextView, context: Context) {
        view.onBubbleTap = onTap
        view.onTextTap = onTextTap
        view.render(text: text, count: count, fontSize: fontSize, lineSpacing: lineSpacing,
                    color: color, continuation: continuation)
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CommentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: ReaderTextLayout.height(of: uiView, width: width))
    }
}

final class CommentTextView: UITextView, UIGestureRecognizerDelegate {
    var onBubbleTap: (() -> Void)?
    var onTextTap: (() -> Void)?
    private var bubbleIndex: Int?
    private var lastRenderKey: String?
    private var paragraphTap: UITapGestureRecognizer?
    private struct Paragraph {
        let text: String
        let count: Int
        let fontSize: CGFloat
        let lineSpacing: CGFloat
        let color: UIColor
        let continuation: Bool
    }
    private var paragraph: Paragraph?
    private var needsTypesetting = false
    private var isTypesetting = false
    private(set) var renderedWidth: CGFloat = 0

    func installTapHandling() {
        guard paragraphTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(paragraphTapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = true
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        addGestureRecognizer(tap)
        paragraphTap = tap
    }

    /// 使用附件实际字形区域，不能用“最近字符”判断（会把行尾空白误当气泡）。
    var bubbleRect: CGRect? {
        // SwiftUI 可能探测过另一提议宽度；点击必须恢复到当前屏幕宽度再取字形。
        if bounds.width > 0 { typeset(width: bounds.width) }
        guard let bubbleIndex, bubbleIndex < textStorage.length else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: bubbleIndex, length: 1),
                                             actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    func isBubble(at point: CGPoint) -> Bool {
        bubbleRect?.contains(point) == true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 没有正文回调时，正文点击交还给翻页容器；气泡始终由本组件处理。
        onTextTap != nil || isBubble(at: touch.location(in: self))
    }

    @objc private func paragraphTapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended else { return }
        if isBubble(at: tap.location(in: self)) { onBubbleTap?() }
        else { onTextTap?() }
    }

    func render(text: String, count: Int, fontSize: CGFloat, lineSpacing: CGFloat,
                color: UIColor, continuation: Bool = false) {
        let key = "\(text)|\(count)|\(fontSize)|\(lineSpacing)|\(continuation)|\(color)"
        guard key != lastRenderKey else { return }
        lastRenderKey = key
        paragraph = Paragraph(text: text, count: count, fontSize: fontSize,
                              lineSpacing: lineSpacing, color: color, continuation: continuation)
        needsTypesetting = true
        typeset(width: bounds.width > 0 ? bounds.width : renderedWidth)
    }

    private func typeset(width: CGFloat) {
        guard !isTypesetting, let paragraph, width.isFinite, width >= 0,
              needsTypesetting || width != renderedWidth else { return }
        isTypesetting = true
        defer { isTypesetting = false }
        // 先更新缓存，避免设置 attributedText 导致 intrinsicContentSize 重入。
        needsTypesetting = false
        renderedWidth = width
        let result = ReaderTextLayout.attributedText(
            text: paragraph.text, count: paragraph.count, fontSize: paragraph.fontSize,
            lineSpacing: paragraph.lineSpacing, color: paragraph.color,
            continuation: paragraph.continuation, width: width > 0 ? width : nil)
        bubbleIndex = paragraph.count > 0 ? result.length - 1 : nil
        attributedText = result
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if size.width.isFinite, size.width > 0 { typeset(width: size.width) }
        let fitted = super.sizeThatFits(size)
        // UITextView 可能临时使用另一宽度进行试排。恢复本次字号/字格对应的容器，
        // 避免屏幕上和段评命中区域仍沿用前一次试排宽度。
        if renderedWidth > 0 { textContainer.size.width = renderedWidth }
        // UIKit/SwiftUI 的滚动宿主必须保留同一提议宽度；短段落的 usedRect 不是正文列宽。
        // 这里只改返回尺寸，重复 layoutSubviews 仍由 typeset 的内容/宽度缓存拦截。
        return CGSize(width: size.width.isFinite && size.width > 0 ? size.width : fitted.width,
                      height: fitted.height)
    }

    override func layoutSubviews() {
        if bounds.width > 0 { typeset(width: bounds.width) }
        super.layoutSubviews()
    }

    override var intrinsicContentSize: CGSize {
        guard bounds.width > 0 else { return CGSize(width: UIView.noIntrinsicMetric, height: 1) }
        return CGSize(width: UIView.noIntrinsicMetric,
                      height: ReaderTextLayout.height(of: self, width: bounds.width))
    }

}
