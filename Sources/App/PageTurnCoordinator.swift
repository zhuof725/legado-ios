import SwiftUI
import UIKit

/// 章节更新、手势和原生动画串行处理；动画过程中不替换数据源快照。
final class PageTurnCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private enum Phase: Equatable { case idle, interactive, animation(UUID), edge(UUID) }
    private weak var vc: UIPageViewController?
    private var applied: PageTurnView
    private var pending: PageTurnView?
    private var phase: Phase = .idle
    private var generation = UUID()
    private var fronts: [Int: ReaderPageHost] = [:]
    private var retiring: [UIViewController] = []
    private var shownIndex = -1
    private var turnGesture: ChapterTurnGesture?
    private var needsContentSettlement = false

    init(_ model: PageTurnView) {
        applied = model
        needsContentSettlement = model.chapterDirection != 0
    }

    var isIdle: Bool { phase == .idle && pending == nil }

    func attach(_ controller: UIPageViewController) {
        vc = controller
        configureDataSource()
    }

    func update(_ model: PageTurnView) {
        pending = model // 合并到最后一份版式/内容；不可在 UIKit 转场中清空 controllers。
        drain()
    }

    private func drain() {
        guard phase == .idle, let model = pending, let vc else { return }
        pending = nil
        let changed = model.contentID != applied.contentID || model.pages.count != applied.pages.count
        let oldFront = visibleFront()
        let direction = model.chapterDirection > 0 ? UIPageViewController.NavigationDirection.forward : .reverse
        let chapterAnimated = changed && oldFront != nil && model.chapterDirection != 0
        if changed {
            retiring = vc.viewControllers ?? []
            // UIKit 仍可能保留旧章邻页，清缓存前关闭它们的无障碍树。
            fronts.values.forEach { $0.setAccessibilityVisible(false) }
            fronts.removeAll()
            generation = UUID()
            turnGesture = nil
            needsContentSettlement = true
        }
        applied = model
        vc.view.backgroundColor = model.background
        vc.view.isOpaque = model.background.cgColor.alpha == 1
        for (index, face) in fronts where model.pages.indices.contains(index) {
            face.updateContent(model.pages[index], background: model.background)
        }
        guard !model.pages.isEmpty else {
            retiring.removeAll()
            finishContentUpdate()
            return
        }
        let index = min(max(model.current, 0), model.pages.count - 1)
        if let visible = visibleFront(), visible.generation == generation, visible.pageIndex == index {
            shownIndex = index
            exposeOnly(visible)
            configureDataSource()
            finishContentUpdate()
            return
        }
        install(index: index, direction: chapterAnimated ? direction : (index < shownIndex ? .reverse : .forward),
                animated: chapterAnimated, isContentUpdate: true)
    }

    private func front(_ index: Int) -> ReaderPageHost? {
        guard applied.pages.indices.contains(index) else { return nil }
        if let cached = fronts[index] { return cached }
        let face = ReaderPageHost(index: index, generation: generation,
                                  content: applied.pages[index], background: applied.background)
        fronts[index] = face
        return face
    }

    private func visibleFront() -> ReaderPageHost? {
        vc?.viewControllers?.first as? ReaderPageHost
    }

    private func exposeOnly(_ visible: ReaderPageHost) {
        let retained = retiring.compactMap { $0 as? ReaderPageHost }
        let mounted = vc?.viewControllers?.compactMap { $0 as? ReaderPageHost } ?? []
        for face in Array(fronts.values) + retained + mounted {
            face.setAccessibilityVisible(face === visible)
        }
        visible.setAccessibilityVisible(true)
    }

    private func configureDataSource() { vc?.dataSource = self }

    private func install(index: Int, direction: UIPageViewController.NavigationDirection,
                         animated: Bool, isContentUpdate: Bool) {
        guard let vc, let target = front(index) else { finishContentUpdate(); return }
        let token = UUID()
        let expectedGeneration = generation
        phase = .animation(token)
        vc.dataSource = nil
        if animated { vc.view.isUserInteractionEnabled = false }
        // 不指定时长、曲线、阴影或纸背，完全使用 UIKit 的原生动画。
        vc.setViewControllers([target], direction: direction, animated: animated) { [weak self, weak vc] _ in
            DispatchQueue.main.async {
                guard let self, let vc, self.phase == .animation(token), self.generation == expectedGeneration else { return }
                if self.visibleFront() !== target || (animated && self.applied.style == .slide) {
                    // 原生 scroll 会缓存旧邻页；退出完成回调后静态确认目标，避免跨章旧页残留。
                    vc.setViewControllers([target], direction: direction, animated: false)
                }
                self.shownIndex = index
                self.exposeOnly(target)
                self.phase = .idle
                self.retiring.removeAll()
                vc.view.isUserInteractionEnabled = true
                self.configureDataSource()
                self.publishCurrent(index, for: expectedGeneration)
                if isContentUpdate { self.finishContentUpdate() }
                DispatchQueue.main.async { [weak self] in self?.drain() }
            }
        }
    }

    private func publishCurrent(_ index: Int, for expected: UUID) {
        var model = applied
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected,
                  self.pending == nil || self.pending?.contentID == model.contentID else { return }
            model.current = index
        }
    }

    private func finishContentUpdate() {
        guard needsContentSettlement else { return }
        needsContentSettlement = false
        let expected = generation
        let callback = applied.onContentTransitionCompleted
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == expected,
                  self.pending == nil || self.pending?.contentID == self.applied.contentID else { return }
            callback()
        }
    }

    // 原生单面阅读页：只提供相邻正文，不插入自制背面或占位页。
    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageHost, face.generation == generation else { return nil }
        return front(face.pageIndex + 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageHost, face.generation == generation else { return nil }
        return front(face.pageIndex - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard phase == .idle else { return }
        phase = .interactive
        turnGesture = nil // 一次手势仅翻一页，倒二→末页不能接着跨章。
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard phase == .interactive else { return }
        phase = .idle
        if let face = visibleFront(), face.generation == generation {
            shownIndex = face.pageIndex
            exposeOnly(face)
            publishCurrent(shownIndex, for: generation)
            configureDataSource()
        } else if shownIndex >= 0 {
            install(index: shownIndex, direction: .forward, animated: false, isContentUpdate: false)
        }
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    @objc func tapped(_ tap: UITapGestureRecognizer) {
        guard phase == .idle, tap.state == .ended, let view = tap.view else { return }
        turnGesture = nil
        let x = tap.location(in: view).x / max(view.bounds.width, 1)
        if x < 0.28 { go(-1) }
        else if x > 0.72 { go(1) }
        else { applied.onTapCenter() }
    }

    @objc func panned(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            turnGesture?.record(pan.translation(in: pan.view))
        case .ended:
            let start = turnGesture
            turnGesture = nil
            guard phase == .idle, var gesture = start, let view = pan.view,
                  shownIndex == gesture.startIndex, applied.pages.count == gesture.pageCount else { return }
            let translation = pan.translation(in: view)
            gesture.record(translation)
            guard let delta = gesture.direction(translation: translation, velocity: pan.velocity(in: view),
                                                 width: view.bounds.width) else { return }
            if (delta > 0 && shownIndex == applied.pages.count - 1) || (delta < 0 && shownIndex == 0) {
                requestEdge(delta)
            }
        case .cancelled, .failed:
            turnGesture = nil
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? ChapterTurnPanObserver else { return phase == .idle }
        let translation = pan.translation(in: pan.view)
        return phase == .idle && turnGesture != nil && abs(translation.x) > abs(translation.y) * 1.25
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard phase == .idle else { return false }
        if recognizer is ChapterTurnPanObserver {
            turnGesture = applied.pages.indices.contains(shownIndex)
                ? ChapterTurnGesture(startIndex: shownIndex, pageCount: applied.pages.count) : nil
            return turnGesture != nil
        }
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            if let paragraph = current as? CommentTextView {
                return !paragraph.isBubble(at: touch.location(in: paragraph))
            }
            view = current.superview
        }
        return true
    }

    private func go(_ delta: Int) {
        guard phase == .idle, applied.pages.indices.contains(shownIndex) else { return }
        turnGesture = nil
        let target = shownIndex + delta
        guard applied.pages.indices.contains(target) else { requestEdge(delta); return }
        install(index: target, direction: delta > 0 ? .forward : .reverse, animated: true, isContentUpdate: false)
    }

    private func requestEdge(_ delta: Int) {
        guard phase == .idle, let vc else { return }
        let token = UUID()
        let expectedGeneration = generation
        let requestedIndex = shownIndex
        phase = .edge(token)
        turnGesture = nil
        let deliver: () -> Void = { [weak self, weak vc] in
            guard let self, let vc, self.phase == .edge(token), self.generation == expectedGeneration else { return }
            // 不在手势分发中替换卷页纹理；下一轮 runloop 先复位，再通知父层。
            if self.applied.style == .curl, let face = self.front(self.shownIndex) {
                vc.dataSource = nil
                vc.setViewControllers([face], direction: .forward, animated: false)
                self.exposeOnly(face)
            }
            self.phase = .idle
            self.configureDataSource() // 即便父层在书尾拒绝跨章，也必须可反向翻回。
            if self.pending != nil { self.drain() }
            // 同章的普通 SwiftUI 更新不能吞掉刚结束的边界手势；真正换页/换章才取消。
            guard self.phase == .idle, self.generation == expectedGeneration,
                  self.shownIndex == requestedIndex,
                  (delta > 0 && requestedIndex == self.applied.pages.count - 1)
                    || (delta < 0 && requestedIndex == 0) else { return }
            self.applied.onEdge(delta)
        }
        if let transition = vc.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in DispatchQueue.main.async(execute: deliver) }) {
            return
        }
        DispatchQueue.main.async(execute: deliver)
    }
}

final class ChapterTurnPanObserver: UIPanGestureRecognizer {
    override func canPrevent(_ other: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by other: UIGestureRecognizer) -> Bool { false }
}

struct ChapterTurnGesture {
    let startIndex: Int
    let pageCount: Int
    private var furthestX: CGFloat = 0
    private var reversed = false

    init(startIndex: Int, pageCount: Int) { self.startIndex = startIndex; self.pageCount = pageCount }
    mutating func record(_ translation: CGPoint) {
        if furthestX * translation.x < 0 { reversed = true }
        if abs(translation.x) > abs(furthestX) { furthestX = translation.x }
    }
    func direction(translation: CGPoint, velocity: CGPoint, width: CGFloat) -> Int? {
        let x = translation.x
        guard !reversed, abs(x) >= max(44, width * 0.18), abs(x) > abs(translation.y) * 1.25,
              furthestX * x > 0, abs(furthestX) - abs(x) <= max(16, width * 0.05),
              x * velocity.x >= 0 || abs(velocity.x) < 100 else { return nil }
        return x < 0 ? 1 : -1
    }
}
