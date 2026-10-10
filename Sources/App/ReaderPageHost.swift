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
/// 只镜像纸张正面的内容；卷曲、渐变、阴影与动画仍完全由公开的 pageCurl 绘制。
final class ReaderPageBack: UIViewController {
    let pageIndex: Int
    let contentID: String
    let generation: UUID
    private let textHost = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))

    init(before index: Int, contentID: String, generation: UUID, content: AnyView,
         background: UIColor, size: CGSize) {
        pageIndex = index
        self.contentID = contentID
        self.generation = generation
        super.init(nibName: nil, bundle: nil)
        if #available(iOS 16.4, *) { textHost.safeAreaRegions = [] }
        // dataSource 可能先于正面布局预取。直接承载正文，不截取尚未布局的空白正面。
        view.bounds = CGRect(origin: .zero, size: size)
        updateContent(content, background: background)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.isOpaque = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        addChild(textHost)
        textHost.view.transform = CGAffineTransform(scaleX: -1, y: 1)
        textHost.view.isUserInteractionEnabled = false
        textHost.view.isAccessibilityElement = false
        textHost.view.accessibilityElementsHidden = true
        view.addSubview(textHost.view)
        textHost.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 不给已变换的 view 设置 frame；UIKit 后续赋予真实尺寸时也会重新布局。
        textHost.view.bounds = CGRect(origin: .zero, size: view.bounds.size)
        textHost.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        textHost.view.layoutIfNeeded()
    }

    func prepareIfNeeded(size: CGSize) {
        // 零尺寸预取不缓存成空纸；再次查询时可先按容器尺寸排版，最终尺寸仍由 UIKit 决定。
        guard view.bounds.isEmpty, size.width > 0, size.height > 0 else { return }
        view.bounds = CGRect(origin: .zero, size: size)
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func updateContent(_ content: AnyView, background: UIColor) {
        textHost.rootView = AnyView(content.allowsHitTesting(false).accessibilityHidden(true))
        view.backgroundColor = background.withAlphaComponent(1)
        textHost.view.backgroundColor = view.backgroundColor
        textHost.view.isOpaque = true
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}
