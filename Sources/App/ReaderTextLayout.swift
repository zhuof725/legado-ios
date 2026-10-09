import UIKit

/// UITextView 和分页器共用同一份属性、TextKit 1 容器及高度算法。
/// 缩进是排版属性，不会改变原文或字符偏移。
enum ReaderTextLayout {
    static func attributedText(text: String, count: Int, fontSize: CGFloat,
                               lineSpacing: CGFloat, color: UIColor,
                               paragraphSpacing: CGFloat = 0,
                               continuation: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.alignment = .natural
        style.firstLineHeadIndent = continuation ? 0 : fontSize * 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let result = NSMutableAttributedString(string: text, attributes: attrs)
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
        private let view: UITextView
        init() {
            precondition(Thread.isMainThread)
            view = ReaderTextLayout.makeTextView()
            ReaderTextLayout.configure(view)
        }
        func height(text: String, count: Int, width: CGFloat, fontSize: CGFloat,
                    lineSpacing: CGFloat, paragraphSpacing: CGFloat = 0, continuation: Bool = false) -> CGFloat {
            view.attributedText = ReaderTextLayout.attributedText(
                text: text, count: count, fontSize: fontSize, lineSpacing: lineSpacing,
                color: .black, paragraphSpacing: paragraphSpacing, continuation: continuation)
            return ReaderTextLayout.height(of: view, width: width)
        }
    }
}
