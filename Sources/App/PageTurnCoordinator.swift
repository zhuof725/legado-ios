import SwiftUI
import UIKit

/// 章节更新、手势和原生动画串行处理；动画过程中不替换数据源快照。
final class PageTurnCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private enum Phase: Equatable { case idle, interactive, animation(UUID), edge(UUID) }
    private weak var vc: ReaderPageViewController?
    private var applied: PageTurnView
    private var pending: PageTurnView?
    private var phase: Phase = .idle
    private var generation = UUID()
    private var fronts: [Int: ReaderPageFace] = [:]
    private var backs: [Int: ReaderPageFace] = [:]
    private var retiring: [UIViewController] = []
    private var shownIndex = -1
    private var turnGesture: ChapterTurnGesture?
    private var needsContentSettlement = false
    private var lastSuppliedBack: ReaderPageFace?

    init(_ model: PageTurnView) {
        applied = model
        needsContentSettlement = model.chapterDirection != 0
    }

    var isIdle: Bool { phase == .idle && pending == nil }

    func attach(_ controller: ReaderPageViewController) {
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
            backs.removeAll()
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
        backs.values.forEach { $0.setPaperColor(model.background) }
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

    private func front(_ index: Int) -> ReaderPageFace? {
        guard applied.pages.indices.contains(index) else { return nil }
        if let cached = fronts[index] { return cached }
        let face = ReaderPageFace(index: index, generation: generation,
                                  content: applied.pages[index], background: applied.background)
        fronts[index] = face
        return face
    }

    private func back(_ index: Int) -> ReaderPageFace {
        if let cached = backs[index] { return cached }
        let face = ReaderPageFace(index: index, generation: generation, content: nil, background: applied.background)
        backs[index] = face
        return face
    }

    private func suppliedBack(_ index: Int) -> ReaderPageFace {
        let face = back(index)
        lastSuppliedBack = face
        return face
    }

    private func visibleFront() -> ReaderPageFace? {
        vc?.viewControllers?.compactMap { $0 as? ReaderPageFace }.first { !$0.isBack }
    }

    private func controllers(for target: ReaderPageFace, previous: ReaderPageFace?,
                             direction: UIPageViewController.NavigationDirection,
                             animated: Bool) -> [UIViewController] {
        // spine.min 的静态展示只有一个可见正面；纸背仅在双面卷页动画时传入。
        guard applied.style == .curl, animated, let previous else { return [target] }
        let paper = direction == .forward ? previous : target
        let paperBack: ReaderPageFace
        if paper.generation != generation {
            paperBack = ReaderPageFace(index: paper.pageIndex, generation: paper.generation,
                                       content: nil, background: applied.background)
        } else {
            paperBack = back(paper.pageIndex)
        }
        lastSuppliedBack = paperBack
        return [target, paperBack]
    }

    private func exposeOnly(_ visible: ReaderPageFace) {
        let retained = retiring.compactMap { $0 as? ReaderPageFace }
        let mounted = vc?.viewControllers?.compactMap { $0 as? ReaderPageFace } ?? []
        for face in Array(fronts.values) + Array(backs.values) + retained + mounted {
            face.setAccessibilityVisible(face === visible)
        }
        visible.setAccessibilityVisible(true)
    }

    private func configureDataSource() {
        vc?.dataSource = applied.style == .fade ? nil : self
    }

    #if DEBUG
    /// 只读最近实际提供给 UIKit 且被加载的纸背；不为探针创建/加载新控制器。
    /// spine.min 静止时 viewControllers 只包含正面，不能要求纸背也在可见数组内。
    func debugBackColor() -> UIColor? {
        guard applied.style == .curl, let face = lastSuppliedBack, face.isViewLoaded else { return nil }
        return face.view.backgroundColor
    }
    #endif

    private func install(index: Int, direction: UIPageViewController.NavigationDirection,
                         animated: Bool, isContentUpdate: Bool) {
        guard let vc, let target = front(index) else { finishContentUpdate(); return }
        let old = visibleFront()
        let targetPair = controllers(for: target, previous: old, direction: direction, animated: animated)
        let token = UUID()
        let expectedGeneration = generation
        phase = .animation(token)
        vc.dataSource = nil // 转场期间固定快照，不允许预取旧章/新版式混合页面。
        if animated { vc.view.isUserInteractionEnabled = false }
        let finished: (Bool) -> Void = { [weak self, weak vc] _ in
            // UIKit 可以同步调用静态安装的 completion；退出它的调用栈再更新/纠正页面。
            DispatchQueue.main.async { [weak self, weak vc] in
                guard let self, let vc, self.phase == .animation(token), self.generation == expectedGeneration else { return }
                if animated || self.visibleFront() !== target {
                    // 系统 scroll 会复用旧邻页；动画退出调用栈后静态确认一次目标，清掉旧队列。
                    // 卷页也移除过渡纸背，但静态复位永远只传一个可见正面。
                    vc.setViewControllers([target], direction: direction, animated: false)
                }
                self.shownIndex = index
                self.exposeOnly(target)
                vc.view.layoutIfNeeded()
                self.phase = .idle
                self.retiring.removeAll()
                vc.view.isUserInteractionEnabled = true
                self.configureDataSource()
                self.publishCurrent(index, for: expectedGeneration)
                if isContentUpdate { self.finishContentUpdate() }
                DispatchQueue.main.async { [weak self] in self?.drain() }
            }
        }
        if animated && applied.style == .fade {
            vc.recordChapterFadeIfNeeded(from: old, to: target)
            UIView.transition(with: vc.view, duration: 0.22, options: [.transitionCrossDissolve, .beginFromCurrentState], animations: {
                vc.setViewControllers(targetPair, direction: direction, animated: false)
            }, completion: { completed in
                vc.finishChapterFadeIfNeeded(from: old, to: target)
                finished(completed)
            })
        } else {
            vc.setViewControllers(targetPair, direction: direction, animated: animated, completion: finished)
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

    // 双面纸的连续序列：正面 i → 背面 i → 正面 i+1；背面永不作为阅读页号。
    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageFace, face.generation == generation else { return nil }
        if applied.style != .curl || face.isBack { return front(face.pageIndex + 1) }
        guard applied.pages.indices.contains(face.pageIndex + 1) else { return nil }
        return suppliedBack(face.pageIndex)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageFace, face.generation == generation else { return nil }
        if applied.style != .curl { return front(face.pageIndex - 1) }
        if face.isBack { return front(face.pageIndex) }
        guard applied.pages.indices.contains(face.pageIndex - 1) else { return nil }
        return suppliedBack(face.pageIndex - 1)
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
            if applied.style == .fade { go(delta) }
            else if (delta > 0 && shownIndex == applied.pages.count - 1) || (delta < 0 && shownIndex == 0) {
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
