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

    var body: some View {
        ZStack(alignment: .top) {
            bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(page.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .paragraph(let t, let count, let url):
                        InlineCommentParagraph(text: t, count: count,
                                                fontSize: fontSize,
                                                lineSpacing: lineSpacing,
                                                color: UIColor(fg),
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
                Spacer(minLength: 0)
                HStack {
                    Text(title).lineLimit(1)
                    Spacer()
                    Text("\(pageNumber)/\(pageCount)")
                }
                .font(.system(size: 11))
                .foregroundStyle(fg.opacity(0.45))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 20)
            .padding(.top, safeInsets.top + 16)
            .padding(.bottom, safeInsets.bottom + 10)
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

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let transition: UIPageViewController.TransitionStyle = style == .curl ? .pageCurl : .scroll
        let vc = UIPageViewController(transitionStyle: transition, navigationOrientation: .horizontal, options: style == .curl ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue] : nil)
        vc.view.backgroundColor = background
        vc.dataSource = style == .fade ? nil : context.coordinator
        vc.delegate = context.coordinator
        if style == .curl { vc.isDoubleSided = false }
        vc.view.clipsToBounds = true
        context.coordinator.attach(vc)
        context.coordinator.reloadIfNeeded(pagesCount: pages.count)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        vc.view.addGestureRecognizer(tap)
        if style == .fade {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panned(_:)))
            vc.view.addGestureRecognizer(pan)
        }
        context.coordinator.show(index: current, animated: false)
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        vc.view.backgroundColor = background
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded(pagesCount: pages.count)
        context.coordinator.show(index: current, animated: false)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: PageTurnView
        private weak var vc: UIPageViewController?
        private var controllers: [Int: UIViewController] = [:]
        private var shownIndex = -1
        private var lastCount = -1
        private var transitioning = false

        init(_ parent: PageTurnView) { self.parent = parent }

        func attach(_ vc: UIPageViewController) { self.vc = vc }

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

        func reloadIfNeeded(pagesCount: Int) {
            if pagesCount != lastCount { controllers.removeAll(); shownIndex = -1; lastCount = pagesCount }
        }

        func show(index: Int, animated: Bool, direction: UIPageViewController.NavigationDirection = .forward) {
            guard !transitioning, let vc, let target = controller(for: index) else { return }
            if shownIndex == index, vc.viewControllers?.first === target { return }
            let dir: UIPageViewController.NavigationDirection = index < shownIndex ? .reverse : direction
            shownIndex = index
            vc.setViewControllers([target], direction: dir, animated: animated, completion: nil)
        }

        // MARK: DataSource（滑动 / 卷页）
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
        }

        // MARK: 点按 / 淡入淡出
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            let x = g.location(in: view).x / max(view.bounds.width, 1)
            if x < 0.28 { go(-1) } else if x > 0.72 { go(1) } else { parent.onTapCenter() }
        }

        @objc func panned(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended else { return }
            let v = g.velocity(in: g.view)
            if abs(v.x) > abs(v.y), abs(v.x) > 200 { go(v.x < 0 ? 1 : -1) }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// 点屏幕两侧翻页；淡入淡出时用交叉淡化，其余用系统动画。
        func go(_ delta: Int) {
            guard !transitioning else { return }
            let next = shownIndex + delta
            if next < 0 { parent.onEdge(-1); return }
            if next >= parent.pages.count { parent.onEdge(1); return }
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
