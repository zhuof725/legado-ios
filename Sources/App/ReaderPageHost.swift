import SwiftUI
import UIKit

/// 仅承载 SwiftUI 正文；卷曲、阴影、纸背和滑动均由 UIPageViewController 管理。
final class ReaderPageHost: UIHostingController<AnyView> {
    let pageIndex: Int
    let generation: UUID

    init(index: Int, generation: UUID, content: AnyView, background: UIColor) {
        pageIndex = index
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
