import SwiftUI
import UIKit

/// UIKit 始终查询冻结的三章快照；正文页和纸背是两种 surface，不是两页阅读进度。
final class PageTurnCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private enum Phase: Equatable { case idle, tracking, interactive(UUID), animation(UUID), edge(UUID), adoption(UUID) }
    private struct Snapshot {
        let generation: UUID
        let pages: [AnyView]
    }
    private struct Key: Hashable {
        let contentID: String
        let generation: UUID
        let index: Int
    }
    private struct Adoption {
        let token: UUID
        let target: Key
    }

    private weak var vc: UIPageViewController?
    private var applied: PageTurnView
    private var pending: PageTurnView?
    private var phase: Phase = .idle
    private var snapshots: [String: Snapshot] = [:]
    private var order: [String] = []
    private var fronts: [Key: ReaderPageHost] = [:]
    private var backs: [Key: ReaderPageBack] = [:]
    private var shown: Key?
    private var interactionOrigin: Key?
    private var adoption: Adoption?
    private var turnGesture: ChapterTurnGesture?
    private var needsContentSettlement = false

    init(_ model: PageTurnView) {
        applied = model
        needsContentSettlement = model.chapterDirection != 0
    }

    var isIdle: Bool { phase == .idle && pending == nil && adoption == nil }
    var isInteractive: Bool {
        if case .interactive = phase { return true }
        return false
    }

    func attach(_ controller: UIPageViewController) {
        vc = controller
        configureDataSource()
    }

    func update(_ model: PageTurnView) {
        if let adoption {
            // 交互期间排队的旧章/旧版式绝不能把已经提交的邻章翻回去。
            // 父层先接纳原快照 ID，随后才可重新分页或导航到其他内容。
            guard model.contentID == adoption.target.contentID else { return }
            guard phase == .adoption(adoption.token) else { return }
            phase = .idle
        }
        pending = model
        drain()
    }

    private func drain() {
        guard phase == .idle, let model = pending, let vc else { return }
        pending = nil
        let oldFront = visibleFront()
        let oldOrder = order
        let oldGenerations = snapshots.mapValues { $0.generation }
        let changed = model.contentID != applied.contentID || model.pages.count != applied.pages.count
        let adopting = adoption?.target.contentID == model.contentID
        if changed { needsContentSettlement = true }
        adoption = nil
        applied = model
        refreshSnapshots(model)
        let topologyChanged = oldOrder != order || oldGenerations != snapshots.mapValues { $0.generation }
        vc.view.backgroundColor = model.background
        vc.view.isOpaque = model.background.cgColor.alpha == 1
        for (key, face) in fronts where valid(key) {
            face.updateContent(snapshots[key.contentID]!.pages[key.index], background: model.background)
        }
        // ID/页数不变时正文与主题也可能刷新；纸背必须刷新逻辑前页，而非目的页。
        for (key, back) in backs {
            if let paper = step(key, -1), let snapshot = snapshots[paper.contentID] {
                back.updateContent(snapshot.pages[paper.index], background: model.background)
            }
        }
        guard let snapshot = snapshots[model.contentID], !snapshot.pages.isEmpty else {
            exposeOnly(nil)
            finishContentUpdate()
            return
        }
        let index = min(max(model.current, 0), snapshot.pages.count - 1)
        let target = Key(contentID: model.contentID, generation: snapshot.generation, index: index)
        let alreadyVisible = oldFront.map { key($0) == target } ?? false
        if alreadyVisible && !topologyChanged {
            shown = target
            exposeOnly(oldFront)
            prune()
            vc.view.isUserInteractionEnabled = true
            configureDataSource()
            finishContentUpdate()
            return
        }
        // theme/rootView 更新或相邻快照更新不动画；接纳已经可见的邻章也不再次翻页。
        let animated = changed && !adopting && !alreadyVisible && oldFront != nil && model.chapterDirection != 0
        let direction: UIPageViewController.NavigationDirection = animated
            ? (model.chapterDirection > 0 ? .forward : .reverse)
            : (index < (shown?.index ?? 0) ? .reverse : .forward)
        install(target, direction: direction, animated: animated, contentUpdate: true, chapterTurn: false)
    }

    private func refreshSnapshots(_ model: PageTurnView) {
        var chapters: [PageTurnChapter] = []
        if let previous = model.previousChapter, previous.contentID != model.contentID, !previous.pages.isEmpty {
            chapters.append(previous)
        }
        chapters.append(PageTurnChapter(contentID: model.contentID, pages: model.pages))
        if let next = model.nextChapter, !chapters.contains(where: { $0.contentID == next.contentID }), !next.pages.isEmpty {
            chapters.append(next)
        }
        var updated: [String: Snapshot] = [:]
        for chapter in chapters {
            let existing = snapshots[chapter.contentID]
            let generation = existing?.pages.count == chapter.pages.count ? existing!.generation : UUID()
            updated[chapter.contentID] = Snapshot(generation: generation, pages: chapter.pages)
        }
        snapshots = updated
        order = chapters.map { $0.contentID }
        for (key, face) in fronts where !valid(key) { face.setAccessibilityVisible(false) }
        fronts = fronts.filter { valid($0.key) }
        backs = backs.filter { valid($0.key) && step($0.key, -1) != nil }
    }

    private func valid(_ key: Key) -> Bool {
        guard let snapshot = snapshots[key.contentID] else { return false }
        return snapshot.generation == key.generation && snapshot.pages.indices.contains(key.index)
    }

    private func key(_ controller: UIViewController) -> Key? {
        if let face = controller as? ReaderPageHost {
            return Key(contentID: face.contentID, generation: face.generation, index: face.pageIndex)
        }
        if let back = controller as? ReaderPageBack {
            return Key(contentID: back.contentID, generation: back.generation, index: back.pageIndex)
        }
        return nil
    }

    private func step(_ key: Key, _ delta: Int) -> Key? {
        guard valid(key), let snapshot = snapshots[key.contentID], let position = order.firstIndex(of: key.contentID) else { return nil }
        let index = key.index + delta
        if snapshot.pages.indices.contains(index) {
            return Key(contentID: key.contentID, generation: key.generation, index: index)
        }
        let adjacent = position + delta
        guard order.indices.contains(adjacent), let neighbor = snapshots[order[adjacent]], !neighbor.pages.isEmpty else { return nil }
        return Key(contentID: order[adjacent], generation: neighbor.generation, index: delta > 0 ? 0 : neighbor.pages.count - 1)
    }

    private func front(_ key: Key) -> ReaderPageHost? {
        guard valid(key), let snapshot = snapshots[key.contentID] else { return nil }
        if let cached = fronts[key] { return cached }
        let face = ReaderPageHost(index: key.index, contentID: key.contentID, generation: key.generation,
                                  content: snapshot.pages[key.index], background: applied.background)
        fronts[key] = face
        return face
    }

    /// B(n) 是 F(n) 之前那张纸的背面：F(n-1) ⇄ B(n) ⇄ F(n)。
    private func back(before key: Key) -> ReaderPageBack? {
        guard let paper = step(key, -1), let snapshot = snapshots[paper.contentID] else { return nil }
        if let cached = backs[key] {
            cached.prepareIfNeeded(size: vc?.view.bounds.size ?? .zero)
            return cached
        }
        let back = ReaderPageBack(before: key.index, contentID: key.contentID,
                                  generation: key.generation, content: snapshot.pages[paper.index],
                                  background: applied.background, size: vc?.view.bounds.size ?? .zero)
        backs[key] = back
        return back
    }

    private func visibleFront() -> ReaderPageHost? {
        vc?.viewControllers?.compactMap { $0 as? ReaderPageHost }.first
    }

    private func exposeOnly(_ visible: ReaderPageHost?) {
        let mounted = vc?.viewControllers?.compactMap { $0 as? ReaderPageHost } ?? []
        for face in Array(fronts.values) + mounted { face.setAccessibilityVisible(face === visible) }
        visible?.setAccessibilityVisible(true)
    }

    private func prune() {
        guard let shown, valid(shown) else { return }
        var keep: Set<Key> = [shown]
        for delta in [-1, 1] {
            if let near = step(shown, delta) {
                keep.insert(near)
                if let second = step(near, delta) { keep.insert(second) }
            }
        }
        for (key, face) in fronts where !keep.contains(key) { face.setAccessibilityVisible(false) }
        fronts = fronts.filter { keep.contains($0.key) }
        backs = backs.filter { keep.contains($0.key) }
    }

    private func configureDataSource() { vc?.dataSource = self }

    /// spine.min 的静态展示只接收一个正面；双面纸背仅在程序动画时传入。
    /// 交互翻页的纸背由 dataSource 提供，不把纸背算成可阅读的一页。
    private func controllers(for target: Key, turningFrom outgoing: ReaderPageHost? = nil,
                             direction: UIPageViewController.NavigationDirection = .forward) -> [UIViewController]? {
        guard let face = front(target) else { return nil }
        guard applied.style == .curl, let outgoing else { return [face] }
        // 前进翻走旧纸；后退翻回目标纸。B(n) 是 F(n) 前一张纸的背面。
        let paper = direction == .forward ? outgoing : face
        if let paperKey = key(paper), let following = step(paperKey, 1), let back = back(before: following) {
            return [face, back]
        }
        // 异步跨章回退时旧章可能已被 refreshSnapshots 淘汰；仍保留实际翻走的正文。
        return [face, ReaderPageBack(before: paper.pageIndex + 1, contentID: paper.contentID,
            generation: paper.generation, content: paper.rootView, background: applied.background,
            size: vc?.view.bounds.size ?? paper.view.bounds.size)]
    }

    private func install(_ target: Key, direction: UIPageViewController.NavigationDirection,
                         animated: Bool, contentUpdate: Bool, chapterTurn: Bool) {
        guard let vc, let pair = controllers(for: target, turningFrom: animated ? visibleFront() : nil,
                                            direction: direction) else { finishContentUpdate(); return }
        let token = UUID()
        let origin = shown
        phase = .animation(token)
        vc.dataSource = nil
        vc.view.isUserInteractionEnabled = false
        // 不设时长、曲线、阴影；curl/scroll 的整段动画完全由原生容器负责。
        vc.setViewControllers(pair, direction: direction, animated: animated) { [weak self, weak vc] _ in
            DispatchQueue.main.async {
                guard let self, let vc, self.phase == .animation(token), self.valid(target) else { return }
                if chapterTurn && self.visibleFront().flatMap({ self.key($0) }) != target {
                    // 原生动画未提交（例如被系统取消）时不能宣布跨章。
                    if let origin, let original = self.controllers(for: origin) {
                        vc.setViewControllers(original, direction: .forward, animated: false)
                        self.shown = origin
                        self.exposeOnly(self.front(origin))
                    }
                    self.phase = .idle
                    vc.view.isUserInteractionEnabled = true
                    self.configureDataSource()
                    self.drain()
                    return
                }
                // flush 原生 scroll 的旧邻页缓存，并将双面 curl 规范为同一静态配对。
                if let settled = self.controllers(for: target) {
                    vc.setViewControllers(settled, direction: direction, animated: false)
                }
                self.shown = target
                self.exposeOnly(self.front(target))
                self.phase = .idle
                self.prune()
                if chapterTurn && target.contentID != self.applied.contentID {
                    self.beginAdoption(target)
                    return
                }
                vc.view.isUserInteractionEnabled = true
                self.configureDataSource()
                self.publishCurrent(target)
                if contentUpdate { self.finishContentUpdate() }
                DispatchQueue.main.async { [weak self] in self?.drain() }
            }
        }
    }

    private func publishCurrent(_ target: Key) {
        // 调用点均已异步退出 UIKit 回调栈。先写同章 Binding，再 drain：pending 的
        // Binding 因而也读取提交页码，不能被交互期间的旧 current 拉回起始页。
        guard phase == .idle, adoption == nil, shown == target, valid(target),
              target.contentID == applied.contentID,
              pending == nil || pending?.contentID == target.contentID else { return }
        if applied.current != target.index { applied.current = target.index }
    }

    private func finishContentUpdate() {
        guard needsContentSettlement else { return }
        needsContentSettlement = false
        let id = applied.contentID
        let callback = applied.onContentTransitionCompleted
        DispatchQueue.main.async { [weak self] in
            guard let self, self.applied.contentID == id, self.adoption == nil,
                  self.pending == nil || self.pending?.contentID == id else { return }
            callback()
        }
    }

    private func beginAdoption(_ target: Key) {
        guard valid(target), target.contentID != applied.contentID,
              let from = order.firstIndex(of: applied.contentID), let to = order.firstIndex(of: target.contentID) else { return }
        let direction = to > from ? 1 : -1
        let token = UUID()
        let callback = applied.onChapterTransition // 与这次手势的冻结快照配对，而非 pending 的闭包。
        pending = nil
        turnGesture = nil
        adoption = Adoption(token: token, target: target)
        phase = .adoption(token)
        vc?.view.isUserInteractionEnabled = false
        // 此时可见的是邻章，但绝不把邻章页码写入旧章 Binding。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .adoption(token), self.adoption?.target == target,
                  self.shown == target, self.valid(target) else { return }
            callback(direction, target.index)
        }
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
        guard let key = key(controller), valid(key) else { return nil }
        if controller is ReaderPageBack { return front(key) }
        guard let next = step(key, 1) else { return nil }
        return applied.style == .curl ? back(before: next) : front(next)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
        guard let key = key(controller), valid(key), let previous = step(key, -1) else { return nil }
        if controller is ReaderPageBack { return front(previous) }
        return applied.style == .curl ? back(before: key) : front(previous)
    }

    func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard phase == .idle || phase == .tracking else { return }
        interactionOrigin = shown
        phase = .interactive(UUID())
        turnGesture = nil // 一次手势只提交一页；倒二→末页不额外触发章末兜底。
    }

    func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard case .interactive(let token) = phase else { return }
        let origin = interactionOrigin
        interactionOrigin = nil
        turnGesture = nil
        // 退出 UIKit 的转场回调栈再更新数据源/SwiftUI，仍保持锁，禁止在回调内重入。
        DispatchQueue.main.async { [weak self, weak pvc] in
            guard let self, let pvc, self.phase == .interactive(token) else { return }
            let visible = self.visibleFront()
            let result = visible.flatMap { self.key($0) }
            let committed = completed && result.map { self.valid($0) } == true
            let target = committed ? result : origin
            guard let target, self.valid(target) else {
                self.phase = .idle
                self.configureDataSource()
                self.drain()
                return
            }
            for face in previousViewControllers.compactMap({ $0 as? ReaderPageHost }) { face.setAccessibilityVisible(false) }
            if !committed || result != target {
                pvc.dataSource = nil
                if let pair = self.controllers(for: target) { pvc.setViewControllers(pair, direction: .forward, animated: false) }
            }
            self.shown = target
            self.exposeOnly(self.front(target))
            self.phase = .idle
            self.prune()
            if committed && target.contentID != self.applied.contentID {
                self.beginAdoption(target)
            } else {
                self.configureDataSource()
                if committed { self.publishCurrent(target) }
                self.drain()
            }
        }
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
        case .began:
            if phase == .idle { phase = .tracking }
            turnGesture?.record(pan.translation(in: pan.view))
        case .changed:
            turnGesture?.record(pan.translation(in: pan.view))
        case .ended:
            let start = turnGesture
            turnGesture = nil
            guard phase == .tracking else { return }
            phase = .idle
            guard var gesture = start, let view = pan.view, let shown,
                  shown.contentID == applied.contentID, shown.index == gesture.startIndex,
                  applied.pages.count == gesture.pageCount else { drain(); return }
            let translation = pan.translation(in: view)
            gesture.record(translation)
            if let delta = gesture.direction(translation: translation, velocity: pan.velocity(in: view), width: view.bounds.width),
               step(shown, delta) == nil,
               (delta > 0 && shown.index == applied.pages.count - 1) || (delta < 0 && shown.index == 0) {
                requestEdge(delta)
            } else {
                // 已准备邻章只能由 UIKit 的 dataSource 原生交互进入，绝不 ended 后补动画。
                DispatchQueue.main.async { [weak self] in self?.drain() }
            }
        case .cancelled, .failed:
            turnGesture = nil
            if phase == .tracking {
                phase = .idle
                DispatchQueue.main.async { [weak self] in self?.drain() }
            }
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
            turnGesture = shown.map { ChapterTurnGesture(startIndex: $0.index, pageCount: applied.pages.count) }
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
        guard phase == .idle, let shown, valid(shown) else { return }
        turnGesture = nil
        guard let target = step(shown, delta) else { requestEdge(delta); return }
        install(target, direction: delta > 0 ? .forward : .reverse, animated: true,
                contentUpdate: false, chapterTurn: target.contentID != applied.contentID)
    }

    private func requestEdge(_ delta: Int) {
        guard phase == .idle, let vc, let requested = shown, valid(requested), step(requested, delta) == nil else { return }
        let token = UUID()
        phase = .edge(token)
        turnGesture = nil
        let deliver: () -> Void = { [weak self, weak vc] in
            guard let self, let vc, self.phase == .edge(token), self.shown == requested, self.valid(requested) else { return }
            // 仅无预分页邻章时走网络兜底。复位依旧遵守双面数组数量，避免回弹内再次动画。
            vc.dataSource = nil
            if let pair = self.controllers(for: requested) {
                vc.setViewControllers(pair, direction: .forward, animated: false)
                self.exposeOnly(self.front(requested))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.phase == .edge(token), self.shown == requested, self.valid(requested) else { return }
                self.phase = .idle
                self.configureDataSource()
                if self.pending != nil { self.drain() }
                guard self.phase == .idle, self.shown == requested, self.valid(requested),
                      self.step(requested, delta) == nil else { return }
                self.applied.onEdge(delta)
            }
        }
        if let transition = vc.transitionCoordinator,
           transition.animate(alongsideTransition: nil, completion: { _ in DispatchQueue.main.async(execute: deliver) }) { return }
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
