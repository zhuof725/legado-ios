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
            fronts.removeAll()
            backs.removeAll()
            generation = UUID()
            turnGesture = nil
            needsContentSettlement = true
        }
        applied = model
        vc.view.backgroundColor = model.background
        vc.view.isOpaque = model.background.cgColor.alpha == 1
        (Array(fronts.values) + Array(backs.values)).forEach { $0.setPaperColor(model.background) }
        guard !model.pages.isEmpty else {
            retiring.removeAll()
            finishContentUpdate()
            return
        }
        let index = min(max(model.current, 0), model.pages.count - 1)
        if let visible = visibleFront(), visible.generation == generation, visible.pageIndex == index {
            shownIndex = index
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

    private func visibleFront() -> ReaderPageFace? {
        vc?.viewControllers?.compactMap { $0 as? ReaderPageFace }.first { !$0.isBack }
    }

    private func pair(for target: ReaderPageFace, previous: ReaderPageFace? = nil) -> [UIViewController] {
        guard applied.style == .curl else { return [target] }
        // spine.min + doubleSided: 正面 + 先前显示纸张的背面（Apple API 要求两个控制器）。
        let paperBack: ReaderPageFace
        if let previous, previous.generation != generation {
            paperBack = ReaderPageFace(index: previous.pageIndex, generation: previous.generation,
                                       content: nil, background: applied.background)
        } else {
            paperBack = back(previous?.pageIndex ?? max(target.pageIndex - 1, 0))
        }
        return [target, paperBack]
    }

    private func configureDataSource() {
        vc?.dataSource = applied.style == .fade ? nil : self
    }

    #if DEBUG
    /// 离线 Harness 查询真实已挂载的纸背，不模拟背景色判断。
    func debugBackColor() -> UIColor? {
        guard applied.style == .curl else { return nil }
        return back(max(shownIndex, 0)).view.backgroundColor
    }
    #endif

    private func install(index: Int, direction: UIPageViewController.NavigationDirection,
                         animated: Bool, isContentUpdate: Bool) {
        guard let vc, let target = front(index) else { finishContentUpdate(); return }
        let old = visibleFront()
        let initialCurl = applied.style == .curl && old == nil && (vc.viewControllers?.isEmpty ?? true)
        let targetPair = initialCurl ? [target] : pair(for: target, previous: old)
        if initialCurl { vc.isDoubleSided = false }
        let token = UUID()
        let expectedGeneration = generation
        phase = .animation(token)
        vc.dataSource = nil // programmatic 用显式两面，不允许 UIKit 预取旧章/新版式混合页面。
        if animated { vc.view.isUserInteractionEnabled = false }
        let finished: (Bool) -> Void = { [weak self, weak vc] completed in
            guard let self, let vc, self.phase == .animation(token), self.generation == expectedGeneration else { return }
            // false 只表示动画被跳过。以当前目标为准，静态收尾后也必须解锁。
            if self.applied.style == .curl {
                // 双面模式下 spine.min 必须传正面+背面；首次初始化先单面，完成后再切双面。
                vc.isDoubleSided = true
                vc.setViewControllers([target, self.back(index)], direction: direction, animated: false)
            } else if self.visibleFront() !== target || !completed {
                vc.setViewControllers(targetPair, direction: direction, animated: false)
            }
            self.shownIndex = index
            self.phase = .idle
            self.retiring.removeAll()
            vc.view.isUserInteractionEnabled = true
            self.configureDataSource()
            self.publishCurrent(index, for: expectedGeneration)
            if isContentUpdate { self.finishContentUpdate() }
            DispatchQueue.main.async { [weak self] in self?.drain() }
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

    // 双面卷页：dataSource 只返回正面；UIKit 自行用“先前显示页的背面”完成配对。
    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageFace, !face.isBack, face.generation == generation else { return nil }
        return front(face.pageIndex + 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        guard let face = controller as? ReaderPageFace, !face.isBack, face.generation == generation else { return nil }
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
        phase = .edge(token)
        turnGesture = nil
        let deliver: () -> Void = { [weak self, weak vc] in
            guard let self, let vc, self.phase == .edge(token), self.generation == expectedGeneration else { return }
            // 不在手势分发中替换卷页纹理；下一轮 runloop 先复位，再通知父层。
            if self.applied.style == .curl, let face = self.front(self.shownIndex) {
                vc.dataSource = nil
                vc.setViewControllers(self.pair(for: face), direction: .forward, animated: false)
            }
            self.phase = .idle
            self.configureDataSource() // 即便父层在书尾拒绝跨章，也必须可反向翻回。
            if self.pending != nil { self.drain(); return }
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
