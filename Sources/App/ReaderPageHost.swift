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
    private var laidOutSize = CGSize.zero
    private var contentNeedsLayout = true

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
        layoutText()
    }

    private func layoutText() {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // 离屏 UIHostingController 不一定收到 UIKit 的布局回调。显式测量才能让
        // UIViewRepresentable 正文在 pageCurl 取纹理之前生成字形与实际高度。
        if contentNeedsLayout || laidOutSize != size {
            contentNeedsLayout = false
            laidOutSize = size
            _ = textHost.sizeThatFits(in: size)
        }
        textHost.view.bounds = CGRect(origin: .zero, size: size)
        textHost.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        textHost.view.setNeedsLayout()
        textHost.view.layoutIfNeeded()
    }

    func prepareIfNeeded(size: CGSize) {
        if view.bounds.isEmpty, size.width > 0, size.height > 0 {
            view.bounds = CGRect(origin: .zero, size: size)
        }
        layoutText()
    }

    func updateContent(_ content: AnyView, background: UIColor) {
        textHost.rootView = AnyView(content.allowsHitTesting(false).accessibilityHidden(true))
        view.backgroundColor = background.withAlphaComponent(1)
        textHost.view.backgroundColor = view.backgroundColor
        textHost.view.isOpaque = true
        contentNeedsLayout = true
        layoutText()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
}
