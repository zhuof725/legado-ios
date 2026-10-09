import UIKit
import CoreText

/// 渲染和分页共用 TextKit 1。只修改属性，不插入字格占位符或改写原文。
enum ReaderTextLayout {
    fileprivate static let baselineKey = NSAttributedString.Key("ReaderTextBaseline")

    struct Metrics {
        let font: UIFont
        let cjkFont: UIFont
        let cellWidth: CGFloat
        let tracking: CGFloat
        let lineHeight: CGFloat
        let baseline: CGFloat
    }

    private struct Fonts {
        let body: UIFont
        let cjk: UIFont
        let advance: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }
    // UIKit 排版入口均在主线程；分页二分测量不重复解析字体。
    private static var fontCache: [CGFloat: Fonts] = [:]

    static func metrics(fontSize: CGFloat, width: CGFloat? = nil) -> Metrics {
        let size = fontSize.isFinite ? max(fontSize, 1) : 19
        let fonts: Fonts
        if let cached = fontCache[size] {
            fonts = cached
        } else {
            let body = UIFont.systemFont(ofSize: size)
            let fallback = CTFontCreateForString(body as CTFont, "汉" as CFString,
                                                CFRange(location: 0, length: 1))
            let cjk = (UIFont(name: CTFontCopyPostScriptName(fallback) as String, size: size) ?? body)
            // 仅中文使用全宽字形，关闭标点的比例宽度；不把西文/emoji 变成等宽字体。
            let descriptor = cjk.fontDescriptor.addingAttributes([
                .featureSettings: [[UIFontDescriptor.FeatureKey.type: kTextSpacingType,
                                    UIFontDescriptor.FeatureKey.selector: kMonospacedTextSelector]]
            ])
            let fullWidth = UIFont(descriptor: descriptor, size: size)
            let emoji = UIFont(name: "AppleColorEmoji", size: size) ?? body
            let bubbleSize = max(size - 5, 11)
            let tail = CommentBubble.tailHeight(for: bubbleSize)
            // 包含气泡（即便本段没有），避免附加气泡或最后一页改变行高。
            let ascent = max(max(body.ascender, fullWidth.ascender),
                             max(emoji.ascender, bubbleSize + tail * 0.5 + 2))
            let descent = max(max(-body.descender, -fullWidth.descender),
                              max(-emoji.descender, tail * 0.5))
            fonts = Fonts(body: body, cjk: fullWidth,
                          advance: max(("汉" as NSString).size(withAttributes: [.font: fullWidth]).width, 1),
                          ascent: ascent, descent: descent)
            fontCache[size] = fonts
        }
        let available = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let columns = available.map { max(floor($0 / fonts.advance), 1) } ?? 1
        let cell = available.map { max($0 / columns, fonts.advance) } ?? fonts.advance
        let height = ceil(fonts.ascent + fonts.descent)
        return Metrics(font: fonts.body, cjkFont: fonts.cjk, cellWidth: cell,
                       tracking: cell - fonts.advance, lineHeight: height,
                       baseline: fonts.ascent + (height - fonts.ascent - fonts.descent) * 0.5)
    }

    /// 只给单标量的全宽 CJK 字符加字距；组合字符、变体选择符、ZWJ 和 Latin run 不拆开。
    private static func isGridCharacter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x303F, 0x3040...0x30FF, 0x3100...0x312F, 0x31A0...0x31BF,
             0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF01...0xFF60, 0xFFE0...0xFFE6,
             0x20000...0x323AF:
            return true
        default:
            return false
        }
    }

    static func attributedText(text: String, count: Int, fontSize: CGFloat,
                               lineSpacing: CGFloat, color: UIColor,
                               continuation: Bool = false, width: CGFloat? = nil) -> NSAttributedString {
        let grid = metrics(fontSize: fontSize, width: width)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(lineSpacing, 0)
        style.minimumLineHeight = grid.lineHeight
        style.maximumLineHeight = grid.lineHeight
        // 段间距和标题仍由外层布局计算；不把最后一行/章尾撑满。
        style.paragraphSpacing = 0
        // justified 会逐行分配余量（首行缩进、避头尾标点时尤其明显），破坏纵向字列。
        // 宽度均分为整数字格，满行接近两端齐；避头尾和混排留下的空白不强行拉伸。
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        style.hyphenationFactor = 0
        style.headIndent = 0
        style.tailIndent = 0
        style.firstLineHeadIndent = continuation ? 0 : grid.cellWidth * 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: grid.font,
            .foregroundColor: color,
            .paragraphStyle: style,
            baselineKey: NSNumber(value: Double(grid.baseline))
        ]
        let result = NSMutableAttributedString(string: text, attributes: attrs)
        var offset = 0
        var runStart: Int?
        func finishRun() {
            guard let start = runStart else { return }
            result.addAttributes([.font: grid.cjkFont, .kern: grid.tracking],
                                 range: NSRange(location: start, length: offset - start))
            runStart = nil
        }
        for character in text {
            if isGridCharacter(character) {
                if runStart == nil { runStart = offset }
            } else {
                finishRun()
            }
            offset += String(character).utf16.count
        }
        finishRun()
        if count > 0 {
            result.append(NSAttributedString(string: " ", attributes: attrs))
            let size = max(fontSize - 5, 11)
            let image = CommentBubble.image(count: count, size: size, color: color)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -CommentBubble.tailHeight(for: size) * 0.5,
                                       width: image.size.width, height: image.size.height)
            let bubble = NSMutableAttributedString(attachment: attachment)
            bubble.addAttributes(attrs, range: NSRange(location: 0, length: bubble.length))
            result.append(bubble)
        }
        return result
    }

    /// 显式使用 TextKit 1，避免测量器和 iOS 16+ UITextView 的默认引擎不同。
    static func makeTextView() -> CommentTextView {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        manager.usesFontLeading = false
        manager.delegate = ReaderLineMetrics.shared
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        return CommentTextView(frame: .zero, textContainer: container)
    }

    static func configure(_ view: UITextView) {
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
    }

    static func height(of view: UITextView, width: CGFloat) -> CGFloat {
        ceil(view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// 一个分页请求复用一个测量 UITextView；必须在主线程使用。
    final class Measurer {
        private let view: CommentTextView
        init() {
            precondition(Thread.isMainThread)
            view = ReaderTextLayout.makeTextView()
            ReaderTextLayout.configure(view)
        }
        func height(text: String, count: Int, width: CGFloat, fontSize: CGFloat,
                    lineSpacing: CGFloat, continuation: Bool = false) -> CGFloat {
            view.render(text: text, count: count, fontSize: fontSize, lineSpacing: lineSpacing,
                        color: .black, continuation: continuation)
            return ReaderTextLayout.height(of: view, width: width)
        }
    }
}

/// TextKit 仍负责塑形、换行、避头尾和附件。只统一行片段内的基线，不移动单个字形。
/// NSLayoutManager.delegate 是弱引用，静态实例确保渲染器/分页器始终使用同一规则。
private final class ReaderLineMetrics: NSObject, NSLayoutManagerDelegate {
    static let shared = ReaderLineMetrics()

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<CGRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, let storage = layoutManager.textStorage else { return false }
        let index = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard index < storage.length,
              let baseline = storage.attribute(ReaderTextLayout.baselineKey, at: index,
                                               effectiveRange: nil) as? NSNumber else { return false }
        baselineOffset.pointee = CGFloat(baseline.doubleValue)
        return true
    }
}
