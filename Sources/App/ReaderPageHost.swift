import SwiftUI
import UIKit

/// 仅承载真实正文；预取页默认不进入 VoiceOver 树。
final class ReaderPageHost: UIHostingController<AnyView> {
    let pageIndex: Int
    let contentID: String
    let generation: UUID

    init(index: Int, contentID: String = "", generation: UUID, content: AnyView, background: UIColor) {
        pageIndex = index
        self.contentID = contentID
        self.generation = generation
        super.init(rootView: content)
        if #available(iOS 16.4, *) { safeAreaRegions = [] }
        view.backgroundColor = background
        view.isOpaque = background.cgColor.alpha == 1
        view.accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateContent(_ content: AnyView, background: UIColor) {
        rootView = content
        view.backgroundColor = background
        view.isOpaque = background.cgColor.alpha == 1
    }

    func setAccessibilityVisible(_ visible: Bool) {
        // 原生容器会预取邻页，只向 VoiceOver 暴露当前阅读页。
        view.accessibilityElementsHidden = !visible
    }
}

/// 某一正文页之前的纸背（即前一张纸的背面），不是可阅读的逻辑页。
/// 只向公开的双面 pageCurl 提供一个 UIView，不绘制卷曲、镜像、渐变或阴影。
final class ReaderPageBack: UIViewController {
    let pageIndex: Int
    let contentID: String
    let generation: UUID

    init(before index: Int, contentID: String, generation: UUID, background: UIColor) {
        pageIndex = index
        self.contentID = contentID
        self.generation = generation
        super.init(nibName: nil, bundle: nil)
        updateBackground(background)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = UIView() }

    func updateBackground(_ background: UIColor) {
        view.backgroundColor = background.withAlphaComponent(1)
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
    }
}
