import SwiftUI
import UIKit

/// 章节标题不截断；分页器和阅读视图使用同一 UILabel 测量方式。
enum ChapterTitleLayout {
    static func label(title: String, fontSize: CGFloat, color: UIColor) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: max(fontSize + 2, 20), weight: .semibold)
        label.textColor = color
        label.text = title
        return label
    }

    static func height(title: String, fontSize: CGFloat, width: CGFloat) -> CGFloat {
        guard !title.isEmpty else { return 0 }
        return ceil(label(title: title, fontSize: fontSize, color: .black)
            .sizeThatFits(CGSize(width: max(width, 1), height: CGFloat.greatestFiniteMagnitude)).height)
    }
}

struct ChapterTitleView: UIViewRepresentable {
    let title: String
    let fontSize: CGFloat
    let color: UIColor

    func makeUIView(context: Context) -> UILabel {
        let label = ChapterTitleLayout.label(title: title, fontSize: fontSize, color: color)
        label.isUserInteractionEnabled = false
        label.accessibilityIdentifier = "chapter-title"
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        label.text = title
        label.font = .systemFont(ofSize: max(fontSize + 2, 20), weight: .semibold)
        label.textColor = color
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: ChapterTitleLayout.height(title: title, fontSize: fontSize, width: width))
    }
}
