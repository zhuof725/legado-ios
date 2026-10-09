import SwiftUI
import UIKit

/// 翻页动画类型（设置里选择）。
enum PageTurnStyle: Int, CaseIterable {
    case slide = 0   // 平移：页面带阴影侧向滑出
    case curl = 1    // 卷页：页角卷起（苹果图书）
    case fade = 2    // 快速淡入淡出

    var title: String {
        switch self {
        case .slide: return "滑动"
        case .curl: return "卷页"
        case .fade: return "淡入淡出"
        }
    }
}

/// 一页内容。放进 UIHostingController，由 UIPageViewController 负责翻页。
struct PageContentView: View {
    let page: BookPage
    let fontSize: Double
    let lineSpacing: Double
    let fg: Color
    let bg: Color
    let title: String
    let pageNumber: Int
    let pageCount: Int
    let onTapComment: (String?) -> Void
    var safeInsets = EdgeInsets()
    var paragraphSpacing: Double = 2
    var leftMargin: Double = 20
    var rightMargin: Double = 20
    var topMargin: Double = 16
    var bottomMargin: Double = 10
    var volumeTitle: String? = nil
    var showsChapterTitle = false

    var body: some View {
        ZStack(alignment: .top) {
            bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if let volumeTitle {
                    Spacer(minLength: 0)
                    VolumeTitleView(title: volumeTitle, foreground: fg)
                    Spacer(minLength: 8)
                } else {
                VStack(alignment: .leading, spacing: CGFloat(paragraphSpacing)) {
                if showsChapterTitle && pageNumber == 1 && !title.isEmpty {
                    ChapterTitleView(title: title, fontSize: CGFloat(fontSize), color: UIColor(fg))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(page.blocks.enumerated()), id: \.offset) { blockIndex, block in
                    switch block {
                    case .paragraph(let t, let count, let url):
                        let continuation = page.continuationIndices.contains(blockIndex)
                        InlineCommentParagraph(text: t, count: count,
                                                fontSize: fontSize,
                                                lineSpacing: lineSpacing,
                                                color: UIColor(fg),
                                                continuation: continuation,
                                                onTap: { onTapComment(url) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .hotComment(let label, let t, let click):
                        HStack(spacing: 10) {
                            Text(label).font(.system(size: max(fontSize - 5, 11), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                            Text(t).font(.system(size: max(fontSize - 3, 12))).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 22).fill(fg.opacity(0.07)))
                        .onTapGesture { onTapComment(click) }
                    case .chapterComments(let t, let count, _, let click):
                        HStack {
                            Text(t).font(.system(size: fontSize - 2, weight: .bold))
                            Spacer()
                            Text(count).font(.system(size: fontSize - 4)).foregroundStyle(fg.opacity(0.7))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(fg.opacity(0.07)))
                        .onTapGesture { onTapComment(click) }
                    case .image(let src, let click):
                        ContentImageView(src: src).onTapGesture { onTapComment(click) }
                    case .inlineBubble:
                        EmptyView()
                    }
                }
                }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg)
            .padding(.leading, CGFloat(leftMargin))
            .padding(.trailing, CGFloat(rightMargin))
            .padding(.top, safeInsets.top + CGFloat(topMargin))
            .padding(.bottom, safeInsets.bottom + CGFloat(bottomMargin) + 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                HStack {
                    Text(title).lineLimit(1)
                    Spacer()
                    Text("\(pageNumber)/\(pageCount)")
                }
                .font(.system(size: 11))
                .foregroundStyle(fg.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .bottom)
                .padding(.leading, CGFloat(leftMargin))
                .padding(.trailing, CGFloat(rightMargin))
                .padding(.bottom, safeInsets.bottom + CGFloat(bottomMargin))
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// UIPageViewController 的 SwiftUI 封装。
/// - 滑动 / 卷页：系统自带的 .scroll / .pageCurl，手势跟手，带阴影。
/// - 淡入淡出：使用 .scroll 的容器，但把翻页过渡替换为交叉淡化（快速）。
struct PageTurnView: UIViewControllerRepresentable {
    let pages: [AnyView]
    @Binding var current: Int
    let style: PageTurnStyle
    let background: UIColor
    /// 翻到章首之前 / 章末之后时通知上层切章。
    let onEdge: (Int) -> Void
    let onTapCenter: () -> Void
    /// 内容身份变化时，保留同一个 UIPageViewController 并用当前动画进入新内容。
    var contentID: String = ""
    var chapterDirection: Int = 0
    var onContentTransitionCompleted: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let transition: UIPageViewController.TransitionStyle = style == .curl ? .pageCurl : .scroll
        let vc = UIPageViewController(transitionStyle: transition, navigationOrientation: .horizontal, options: style == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil)
        vc.view.backgroundColor = background
        context.coordinator.setBackground(background)
        vc.dataSource = style == .fade ? nil : context.coordinator
        vc.delegate = context.coordinator
        if style == .curl { vc.isDoubleSided = false }
        vc.view.clipsToBounds = true
        context.coordinator.attach(vc)
        context.coordinator.reloadIfNeeded(pagesCount: pages.count, contentID: contentID)
        // 只观察拖动，不接管系统 scroll / pageCurl 的交互或手势代理。
        let pan = ChapterTurnPanObserver(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        vc.view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        // 短拖动即使没有达到翻页阈值，也不能再被当作边缘点击。
        // 仅约束我们自己的 tap，不给 UIKit 内部手势添加失败依赖。
        tap.require(toFail: pan)
        vc.view.addGestureRecognizer(tap)
        context.coordinator.show(index: current, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        vc.view.backgroundColor = background
        context.coordinator.setBackground(background)
        context.coordinator.parent = self
        vc.dataSource = style == .fade ? nil : context.coordinator
        context.coordinator.reloadIfNeeded(pagesCount: pages.count, contentID: contentID)
        context.coordinator.show(index: current, animated: false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PageTurnView
        private weak var vc: UIPageViewController?
        private var controllers: [Int: UIViewController] = [:]
        private var shownIndex = -1
        private var lastCount = -1
        private var lastContentID = ""
        private var transitioning = false
        private var pendingContentID: String?
        private var turnGesture: ChapterTurnGesture?

        init(_ parent: PageTurnView) { self.parent = parent }

        func attach(_ vc: UIPageViewController) { self.vc = vc }

        func setBackground(_ color: UIColor) {
            vc?.view.backgroundColor = color
            controllers.values.forEach { $0.view.backgroundColor = color }
        }

        private func controller(for index: Int) -> UIViewController? {
            guard index >= 0, index < parent.pages.count else { return nil }
            if let c = controllers[index] { return c }
            let host = UIHostingController(rootView: parent.pages[index])
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            host.view.backgroundColor = parent.background
            host.view.tag = index
            controllers[index] = host
            return host
        }

        func reloadIfNeeded(pagesCount: Int, contentID: String) {
            let pageCountChanged = pagesCount != lastCount
            let contentChanged = !contentID.isEmpty && contentID != lastContentID
            if pageCountChanged || contentChanged {
                turnGesture = nil
                controllers.removeAll()
                // 新章第一页应从索引 0 开始；保留一个方向快照，
                // show() 会以新内容的第一页沿当前动画进入。
                if contentChanged { shownIndex = -1 }
                lastCount = pagesCount
            }
            if contentChanged {
                lastContentID = contentID
                pendingContentID = contentID
            }
        }

        func show(index: Int, animated: Bool, direction: UIPageViewController.NavigationDirection = .forward) {
            guard !transitioning, let vc, let target = controller(for: index) else { return }
            if shownIndex == index, vc.viewControllers?.first === target {
                if pendingContentID != nil { pendingContentID = nil }
                return
            }
            turnGesture = nil
            let chapterAnimated = pendingContentID != nil && parent.chapterDirection != 0
            let shouldAnimate = animated || chapterAnimated
            let dir: UIPageViewController.NavigationDirection = chapterAnimated
                ? (parent.chapterDirection > 0 ? .forward : .reverse)
                : (index < shownIndex ? .reverse : direction)
            shownIndex = index
            let contentID = pendingContentID
            if shouldAnimate { transitioning = true }
            let finish: (Bool) -> Void = { [weak self] completed in
                guard let self else { return }
                self.transitioning = false
                if contentID != nil { self.pendingContentID = nil }
                if completed, contentID != nil {
                    DispatchQueue.main.async { self.parent.onContentTransitionCompleted() }
                }
            }
            if chapterAnimated && parent.style == .fade {
                UIView.transition(with: vc.view, duration: 0.22,
                                  options: [.transitionCrossDissolve, .allowUserInteraction]) {
                    vc.setViewControllers([target], direction: dir, animated: false, completion: nil)
                } completion: { _ in finish(true) }
            } else {
                vc.setViewControllers([target], direction: dir, animated: shouldAnimate,
                                       completion: finish)
            }
        }

        // MARK: DataSource（滑动 / 卷页）
        // UIKit 会预取相邻页：这里只返回本章真实页面，不能在预取中切章或插入占位页。
        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            let i = viewController.view.tag - 1
            if i < 0 { return nil }
            return controller(for: i)
        }
        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            let i = viewController.view.tag + 1
            if i >= parent.pages.count { return nil }
            return controller(for: i)
        }
        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            transitioning = false
            guard let i = pvc.viewControllers?.first?.view.tag else { return }
            shownIndex = i
            DispatchQueue.main.async { self.parent.current = i }
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            transitioning = true
            // 本次触摸已交给系统翻本章页面，即使随后取消也不能再拿它跨章。
            turnGesture = nil
        }

        // MARK: 点按 / 拖动观察
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard g.state == .ended, let view = g.view else { return }
            turnGesture = nil
            let x = g.location(in: view).x / max(view.bounds.width, 1)
            if x < 0.28 { go(-1) } else if x > 0.72 { go(1) } else { parent.onTapCenter() }
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed:
                turnGesture?.record(g.translation(in: g.view))
            case .ended:
                let start = turnGesture
                turnGesture = nil
                guard var gesture = start, let view = g.view, !transitioning,
                      shownIndex == gesture.startIndex, parent.pages.count == gesture.pageCount else { return }
                let translation = g.translation(in: view)
                gesture.record(translation)
                guard let delta = gesture.direction(translation: translation, velocity: g.velocity(in: view),
                                                     width: view.bounds.width) else { return }
                if parent.style == .fade {
                    go(delta)
                } else if (delta > 0 && gesture.startIndex == gesture.pageCount - 1)
                            || (delta < 0 && gesture.startIndex == 0) {
                    // 判断触摸开始页，而非结束页：倒数第二页 -> 末页只能正常翻一页。
                    requestEdge(delta)
                }
            case .cancelled, .failed:
                turnGesture = nil
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? ChapterTurnPanObserver else { return true }
            let translation = pan.translation(in: pan.view)
            return turnGesture != nil && abs(translation.x) > abs(translation.y) * 1.25
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer is ChapterTurnPanObserver {
                // 在 touchesBegan 阶段取快照；等 pan.began 时，UIKit 可能已开始翻页。
                turnGesture = !transitioning && parent.pages.indices.contains(shownIndex)
                    ? ChapterTurnGesture(startIndex: shownIndex, pageCount: parent.pages.count) : nil
                return turnGesture != nil
            }
            // 只有点按排除实际气泡区域；从气泡起手的真实拖动仍可正常翻页。
            var view = touch.view
            while let current = view {
                if let paragraph = current as? CommentTextView {
                    return !paragraph.isBubble(at: touch.location(in: paragraph))
                }
                view = current.superview
            }
            return true
        }

        private func stopInteractiveTransitionForEdge() {
            guard parent.style == .curl, let vc else { return }
            // 系统 pageCurl 没有 dataSource 时会把边界拖动留在交互层；
            // 先撤掉 dataSource 并同步回到当前控制器，再让父层加载下一章。
            vc.dataSource = nil
            if let current = vc.viewControllers?.first {
                vc.setViewControllers([current], direction: .forward, animated: false, completion: nil)
            }
            transitioning = false
            turnGesture = nil
        }

        private func requestEdge(_ delta: Int) {
            guard parent.style == .curl, let vc, let coordinator = vc.transitionCoordinator else {
                stopInteractiveTransitionForEdge()
                DispatchQueue.main.async { self.parent.onEdge(delta) }
                return
            }
            // 让当前卷页先回到稳定状态，再切换章节；否则 SwiftUI 重建页面会留下窄条卷页层。
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                guard let self else { return }
                self.stopInteractiveTransitionForEdge()
                self.parent.onEdge(delta)
            }
        }

        /// 点屏幕两侧翻页；淡入淡出时用交叉淡化，其余用系统动画。
        func go(_ delta: Int) {
            guard !transitioning, parent.pages.indices.contains(shownIndex) else { return }
            turnGesture = nil
            let next = shownIndex + delta
            if next < 0 { requestEdge(-1); return }
            if next >= parent.pages.count { requestEdge(1); return }
            guard let vc, let target = controller(for: next) else { return }
            let dir: UIPageViewController.NavigationDirection = delta > 0 ? .forward : .reverse
            transitioning = true
            if parent.style == .fade {
                UIView.transition(with: vc.view, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction], animations: {
                    vc.setViewControllers([target], direction: dir, animated: false, completion: nil)
                }, completion: { _ in self.completeTurn(next) })
            } else {
                vc.setViewControllers([target], direction: dir, animated: true) { completed in
                    if completed { self.completeTurn(next) } else { self.transitioning = false }
                }
            }
        }

        private func completeTurn(_ next: Int) {
            shownIndex = next
            transitioning = false
            DispatchQueue.main.async { self.parent.current = next }
        }
    }
}

/// 边界没有相邻控制器，系统手势可能直接失败；观察器必须仍能收到整个拖动。
/// 不替换 UIKit 的 delegate，不阻止（也不被阻止于）内部 scroll / curl 手势。
private final class ChapterTurnPanObserver: UIPanGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

/// 一次真实触摸的快照；没有跨触摸的定时门锁，跨章加载防重由父层负责。
private struct ChapterTurnGesture {
    let startIndex: Int
    let pageCount: Int
    private var furthestX: CGFloat = 0
    private var reversed = false

    init(startIndex: Int, pageCount: Int) {
        self.startIndex = startIndex
        self.pageCount = pageCount
    }

    mutating func record(_ translation: CGPoint) {
        if furthestX * translation.x < 0 { reversed = true }
        if abs(translation.x) > abs(furthestX) { furthestX = translation.x }
    }

    func direction(translation: CGPoint, velocity: CGPoint, width: CGFloat) -> Int? {
        let x = translation.x
        // 速度不能把短拖动变成跨章；先要求实际位移和明确的水平方向。
        // 拉回取消（含停住后松手）或反向甩回，也不提交。
        guard !reversed, abs(x) >= max(44, width * 0.18),
              abs(x) > abs(translation.y) * 1.25,
              furthestX * x > 0,
              abs(furthestX) - abs(x) <= max(16, width * 0.05),
              x * velocity.x >= 0 || abs(velocity.x) < 100 else { return nil }
        return x < 0 ? 1 : -1
    }
}
