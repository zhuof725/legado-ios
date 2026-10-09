import SwiftUI
import UIKit

/// 一张纸的一个面。背面是纯主题色，不让 UIKit 自动合成白底镜像文字。
final class ReaderPageFace: UIViewController {
    let pageIndex: Int
    let generation: UUID
    let isBack: Bool
    private var paperColor: UIColor
    private let content: AnyView?
    private var host: UIHostingController<AnyView>?

    init(index: Int, generation: UUID, content: AnyView?, background: UIColor) {
        pageIndex = index
        self.generation = generation
        self.content = content
        isBack = content == nil
        paperColor = background
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = paperColor
        view.isOpaque = true
        if isBack {
            view.accessibilityIdentifier = "reader-page-back"
            view.accessibilityElementsHidden = true
        } else if let content {
            let hosting = UIHostingController(rootView: content)
            if #available(iOS 16.4, *) { hosting.safeAreaRegions = [] }
            addChild(hosting)
            hosting.view.backgroundColor = paperColor
            hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(hosting.view)
            hosting.didMove(toParent: self)
            host = hosting
        }
    }

    func setPaperColor(_ color: UIColor) {
        paperColor = color
        guard isViewLoaded else { return }
        view.backgroundColor = color
        host?.view.backgroundColor = color
    }
}

/// 只记录系统实际收到的动画调用，便于验证“跨章完成”不是静态替换页面。
final class ReaderPageViewController: UIPageViewController {
    private(set) var chapterAnimationRequests = 0
    private(set) var chapterAnimationCompletions = 0
    private(set) var lastChapterAnimation = "none"
    #if DEBUG
    var onChapterAnimationStarted: (() -> Void)?
    #endif

    override func setViewControllers(_ viewControllers: [UIViewController]?,
                                    direction: UIPageViewController.NavigationDirection,
                                    animated: Bool, completion: ((Bool) -> Void)? = nil) {
        let old = self.viewControllers?.compactMap { $0 as? ReaderPageFace }.first { !$0.isBack }
        let new = viewControllers?.compactMap { $0 as? ReaderPageFace }.first { !$0.isBack }
        let chapterTurn = animated && old != nil && new != nil && old?.generation != new?.generation
        if chapterTurn {
            chapterAnimationRequests += 1
            lastChapterAnimation = transitionStyle == .pageCurl ? "curl" : "slide"
            #if DEBUG
            onChapterAnimationStarted?()
            #endif
        }
        super.setViewControllers(viewControllers, direction: direction, animated: animated) { [weak self] completed in
            if chapterTurn { self?.chapterAnimationCompletions += 1 }
            completion?(completed)
        }
    }

    func recordChapterFadeIfNeeded(from old: ReaderPageFace?, to new: ReaderPageFace) {
        guard let old, old.generation != new.generation else { return }
        chapterAnimationRequests += 1
        lastChapterAnimation = "fade"
        #if DEBUG
        onChapterAnimationStarted?()
        #endif
    }
    func finishChapterFadeIfNeeded(from old: ReaderPageFace?, to new: ReaderPageFace) {
        guard let old, old.generation != new.generation else { return }
        chapterAnimationCompletions += 1
    }
}
