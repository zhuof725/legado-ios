import SwiftUI
import UIKit

struct ReaderCoverPageTurnView: UIViewControllerRepresentable {
    let model: PageTurnView

    func makeUIViewController(context: Context) -> ReaderCoverPageTurnController {
        ReaderCoverPageTurnController(model: model)
    }

    func updateUIViewController(_ controller: ReaderCoverPageTurnController, context: Context) {
        controller.update(model)
    }

    static func dismantleUIViewController(_ controller: ReaderCoverPageTurnController, coordinator: ()) {
        controller.stop()
    }
}

/// 一次只挂载当前页和目的页；冻结真实 SwiftUI 内容，拖动期间不重新布局正文。
final class ReaderCoverPageTurnController: UIViewController, UIGestureRecognizerDelegate {
    private struct Key: Equatable {
        let contentID: String
        let count: Int
        let index: Int
    }
    private struct Page {
        let key: Key
        let surface: CoverPageSurface
    }
    private struct Turn {
        let token = UUID()
        let from: Page
        let to: Page
        let direction: Int
        let model: PageTurnView
        let contentUpdate: Bool
        var cover: CoverPageSurface { direction > 0 ? from.surface : to.surface }
    }
    private enum Phase: Equatable {
        case idle, tracking, animation(UUID), settling(UUID), adoption(UUID), edge(UUID)
    }

    private var applied: PageTurnView
    private var pending: PageTurnView?
    private var phase: Phase = .idle
    private var shown: Page?
    private var spare: Page?
    private var turn: Turn?
    private var adoption: Key?
    private var animator: UIViewPropertyAnimator?
    private var progress: CGFloat = 0
    private var dragDirection = 0
    private var layoutSize = CGSize.zero
    private var needsContentSettlement: Bool
    private var stopped = false
    private let dim = UIView()

    private lazy var pan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = self
        return gesture
    }()

    init(model: PageTurnView) {
        applied = model
        needsContentSettlement = model.chapterDirection != 0
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isIdle: Bool { !stopped && phase == .idle && pending == nil && adoption == nil }
    #if DEBUG
    var inspection: [String: Any] {
        let cover = turn?.cover
        let under = turn.map { $0.direction > 0 ? $0.to.surface : $0.from.surface }
        return ["idle": isIdle, "tracking": phase == .tracking, "progress": Double(progress),
            "contentID": shown?.key.contentID ?? "", "page": shown?.key.index ?? -1,
            "coverX": Double(cover?.view.transform.tx ?? 0), "underX": Double(under?.view.transform.tx ?? 0),
            "corner": Double(cover?.cornerRadius ?? 0), "dim": Double(dim.alpha),
            "width": Double(view.bounds.width)]
    }
    #endif

    override func loadView() {
        view = UIView()
        view.clipsToBounds = true
        view.backgroundColor = applied.background
        view.isOpaque = applied.background.cgColor.alpha == 1
        dim.backgroundColor = .black
        dim.isUserInteractionEnabled = false
        dim.accessibilityElementsHidden = true
        dim.isHidden = true
        view.addSubview(dim)
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tap.cancelsTouchesInView = false
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update(applied)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard layoutSize != view.bounds.size else { return }
        layoutSize = view.bounds.size
        // 旋转/尺寸改变取消交互；程序化换章已经由父层接纳，直接完成到目标页。
        if let turn {
            animator?.stopAnimation(true)
            animator = nil
            finish(turn, committed: turn.contentUpdate)
        }
        for child in children.compactMap({ $0 as? CoverPageSurface }) {
            child.view.bounds = CGRect(origin: .zero, size: layoutSize)
            child.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        dim.frame = view.bounds
    }

    func update(_ model: PageTurnView) {
        guard !stopped else { return }
        if let adoption {
            // 邻章提交后拒绝旧章/旧版式，先原子接纳父层持有的同一快照 ID。
            guard model.contentID == adoption.contentID else { return }
            guard case .adoption = phase else { return }
            phase = .idle
        }
        pending = model
        if isViewLoaded { drain() }
    }

    private func drain() {
        guard phase == .idle, let model = pending else { return }
        pending = nil
        let old = shown
        let changed = applied.contentID != model.contentID || applied.pages.count != model.pages.count
        let adopting = adoption?.contentID == model.contentID
        adoption = nil
        applied = model
        if changed { needsContentSettlement = true }
        guard !model.pages.isEmpty else {
            clearPages()
            applyBackground(model.background)
            finishContentUpdate()
            return
        }
        let index = min(max(model.current, 0), model.pages.count - 1)
        let key = Key(contentID: model.contentID, count: model.pages.count, index: index)
        if let old, old.key == key {
            old.surface.update(model.pages[index], background: model.background)
            if let spare, let content = content(for: spare.key) {
                spare.surface.update(content, background: model.background)
            } else { discardSpare() }
            applyBackground(model.background)
            exposeOnly(old.surface)
            finishContentUpdate()
            return
        }
        let target = page(key, content: model.pages[index])
        // 同 ID 正文、主题更新不重启动画；已跟手提交的预分页邻章不再翻一次。
        if let old, changed, !adopting, model.chapterDirection != 0, view.bounds.width > 0 {
            begin(from: old, to: target, direction: model.chapterDirection > 0 ? 1 : -1, contentUpdate: true)
            animate(committed: true, velocity: 0)
        } else {
            settle(on: target, other: old)
            applyBackground(model.background)
            finishContentUpdate()
        }
    }

    private func content(for key: Key) -> AnyView? {
        let chapter: PageTurnChapter?
        if key.contentID == applied.contentID {
            chapter = PageTurnChapter(contentID: applied.contentID, pages: applied.pages)
        } else if key.contentID == applied.previousChapter?.contentID {
            chapter = applied.previousChapter
        } else if key.contentID == applied.nextChapter?.contentID {
            chapter = applied.nextChapter
        } else { chapter = nil }
        guard let chapter, chapter.pages.count == key.count, chapter.pages.indices.contains(key.index) else { return nil }
        return chapter.pages[key.index]
    }

    private func neighbor(_ direction: Int) -> Key? {
        guard let shown, shown.key.contentID == applied.contentID else { return nil }
        let index = shown.key.index + direction
        if applied.pages.indices.contains(index) {
            return Key(contentID: applied.contentID, count: applied.pages.count, index: index)
        }
        guard let chapter = direction > 0 ? applied.nextChapter : applied.previousChapter,
              chapter.contentID != applied.contentID, !chapter.pages.isEmpty else { return nil }
        return Key(contentID: chapter.contentID, count: chapter.pages.count,
                   index: direction > 0 ? 0 : chapter.pages.count - 1)
    }

    private func page(_ key: Key, content: AnyView) -> Page {
        if let spare, spare.key == key {
            self.spare = nil
            spare.surface.update(content, background: applied.background)
            spare.surface.view.isHidden = false
            return spare
        }
        discardSpare()
        let surface = CoverPageSurface(content: content, background: applied.background)
        addChild(surface)
        surface.view.frame = view.bounds
        view.addSubview(surface.view)
        surface.didMove(toParent: self)
        return Page(key: key, surface: surface)
    }

    private func discardSpare() {
        if let spare { unmount(spare.surface) }
        spare = nil
    }

    private func unmount(_ surface: CoverPageSurface) {
        surface.willMove(toParent: nil)
        surface.view.removeFromSuperview()
        surface.removeFromParent()
    }

    private func clearPages() {
        for surface in children.compactMap({ $0 as? CoverPageSurface }) { unmount(surface) }
        shown = nil
        spare = nil
        dim.isHidden = true
    }

    private func applyBackground(_ background: UIColor) {
        view.backgroundColor = background
        view.isOpaque = background.cgColor.alpha == 1
    }

    private func exposeOnly(_ surface: CoverPageSurface?) {
        for child in children.compactMap({ $0 as? CoverPageSurface }) {
            child.view.accessibilityElementsHidden = child !== surface
            child.view.isUserInteractionEnabled = child === surface
        }
    }

    private func settle(on page: Page, other: Page?) {
        shown = page
        spare = other
        for child in children.compactMap({ $0 as? CoverPageSurface }) {
            child.view.transform = .identity
            child.setRounding(0)
            child.view.layer.shadowOpacity = 0
            child.view.isHidden = child !== page.surface
        }
        dim.isHidden = true
        dim.alpha = 0
        exposeOnly(page.surface)
    }

    private func begin(from: Page, to: Page, direction: Int, contentUpdate: Bool) {
        view.layoutIfNeeded()
        from.surface.view.layoutIfNeeded()
        to.surface.view.layoutIfNeeded()
        let next = Turn(from: from, to: to, direction: direction, model: applied, contentUpdate: contentUpdate)
        turn = next
        phase = .tracking
        progress = 0
        from.surface.view.isHidden = false
        to.surface.view.isHidden = false
        let underlying = direction > 0 ? to.surface : from.surface
        underlying.view.transform = .identity
        underlying.setRounding(0)
        underlying.view.layer.shadowOpacity = 0
        view.bringSubviewToFront(underlying.view)
        view.bringSubviewToFront(dim)
        view.bringSubviewToFront(next.cover.view)
        dim.frame = view.bounds
        dim.isHidden = false
        // 两个真实页面继续受容器管理，仅逻辑当前页进入辅助功能树。
        exposeOnly(from.surface)
        from.surface.view.isUserInteractionEnabled = false
        to.surface.view.isUserInteractionEnabled = false
        render(0)
    }

    private func render(_ value: CGFloat) {
        guard let turn else { return }
        progress = min(max(value, 0), 1)
        let offset = turn.direction > 0 ? progress : 1 - progress
        let rounding = min(offset / 0.22, 1)
        turn.cover.view.transform = CGAffineTransform(translationX: -view.bounds.width * offset, y: 0)
        turn.cover.setRounding(min(65, view.bounds.width * 0.18) * rounding)
        turn.cover.view.layer.shadowOpacity = Float(0.16 * rounding)
        // 下层从不平移/缩放；只有一层至多 10% 的黑色遮罩。
        dim.alpha = 0.10 * (1 - offset)
    }

    private func animate(committed: Bool, velocity: CGFloat) {
        guard let turn else { return }
        let end: CGFloat = committed ? 1 : 0
        let distance = abs(end - progress)
        phase = .animation(turn.token)
        let speed = abs(velocity) / max(view.bounds.width, 1)
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.12
            : min(0.36, max(0.16, Double(distance / max(speed, 2.8))))
        let animation = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak self] in
            self?.render(end)
        }
        animator = animation
        animation.addCompletion { [weak self] position in
            guard let self, self.phase == .animation(turn.token) else { return }
            self.animator = nil
            self.finish(turn, committed: (position == .end && committed) || turn.contentUpdate)
        }
        animation.startAnimation()
    }

    private func finish(_ completed: Turn, committed: Bool) {
        guard turn?.token == completed.token else { return }
        turn = nil
        dragDirection = 0
        phase = .settling(completed.token)
        let target = committed ? completed.to : completed.from
        settle(on: target, other: committed ? completed.from : completed.to)
        // 退出 UIKit 动画/布局回调后才写 SwiftUI 状态，避免重入和旧 Binding 回写。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.phase == .settling(completed.token) else { return }
            if committed && !completed.contentUpdate && target.key.contentID != completed.model.contentID {
                self.pending = nil
                self.adoption = target.key
                self.phase = .adoption(completed.token)
                self.shown?.surface.view.isUserInteractionEnabled = false
                completed.model.onChapterTransition(completed.direction, target.key.index)
                return
            }
            self.phase = .idle
            if committed && !completed.contentUpdate,
               target.key.contentID == self.applied.contentID,
               self.pending == nil || self.pending?.contentID == target.key.contentID,
               self.applied.current != target.key.index {
                self.applied.current = target.key.index
            }
            if completed.contentUpdate {
                self.applyBackground(self.applied.background)
                self.finishContentUpdate()
            }
            self.drain()
        }
    }

    private func finishContentUpdate() {
        guard needsContentSettlement else { return }
        needsContentSettlement = false
        let id = applied.contentID
        let callback = applied.onContentTransitionCompleted
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.applied.contentID == id, self.adoption == nil,
                  self.pending == nil || self.pending?.contentID == id else { return }
            callback()
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        switch gesture.state {
        case .began:
            guard phase == .idle, let shown else { return }
            dragDirection = (translation.x == 0 ? velocity.x : translation.x) < 0 ? 1 : -1
            phase = .tracking
            if let key = neighbor(dragDirection), let content = content(for: key) {
                begin(from: shown, to: page(key, content: content), direction: dragDirection, contentUpdate: false)
                render(-translation.x * CGFloat(dragDirection) / max(view.bounds.width, 1))
            }
        case .changed:
            guard phase == .tracking, turn != nil else { return }
            render(-translation.x * CGFloat(dragDirection) / max(view.bounds.width, 1))
        case .ended:
            guard phase == .tracking else { return }
            let travel = -translation.x * CGFloat(dragDirection)
            let speed = -velocity.x * CGFloat(dragDirection)
            let width = max(view.bounds.width, 1)
            if turn != nil {
                render(travel / width)
                // 回拉优先取消；明确的快速轻扫或超过阈值的慢拖才提交。
                let commit = travel > 10 && speed > -160
                    && (travel / width > 0.33 || speed > 550)
                animate(committed: commit, velocity: velocity.x)
            } else {
                let direction = dragDirection
                dragDirection = 0
                phase = .idle
                if travel >= max(44, width * 0.18), speed > -100 {
                    requestEdge(direction)
                } else { drain() }
            }
        case .cancelled, .failed:
            guard phase == .tracking else { return }
            if turn != nil { animate(committed: false, velocity: 0) }
            else { phase = .idle; dragDirection = 0; drain() }
        default: break
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard phase == .idle, gesture.state == .ended else { return }
        let x = gesture.location(in: view).x / max(view.bounds.width, 1)
        if x < 0.28 { go(-1) }
        else if x > 0.72 { go(1) }
        else { applied.onTapCenter() }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard isIdle, shown != nil, view.bounds.width > 0 else { return false }
        guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
        let translation = pan.translation(in: view)
        let delta = translation == .zero ? pan.velocity(in: view) : translation
        return abs(delta.x) > abs(delta.y) * 1.25
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isIdle, shown != nil else { return false }
        var ancestor = touch.view
        while let node = ancestor {
            if node is UIControl { return false }
            if let paragraph = node as? CommentTextView,
               paragraph.isBubble(at: touch.location(in: paragraph)) { return false }
            ancestor = node.superview
        }
        return true
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        guard isIdle, shown != nil else { return false }
        if direction == .left { go(1); return true }
        if direction == .right { go(-1); return true }
        return false
    }

    private func go(_ direction: Int) {
        guard phase == .idle, let shown else { return }
        guard let key = neighbor(direction), let content = content(for: key) else {
            requestEdge(direction)
            return
        }
        begin(from: shown, to: page(key, content: content), direction: direction, contentUpdate: false)
        animate(committed: true, velocity: 0)
    }

    private func requestEdge(_ direction: Int) {
        guard phase == .idle, let origin = shown?.key, neighbor(direction) == nil else { return }
        let token = UUID()
        phase = .edge(token)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.phase == .edge(token) else { return }
            self.phase = .idle
            self.drain()
            guard self.phase == .idle, self.shown?.key == origin, self.neighbor(direction) == nil else { return }
            // 未预加载的章节保持旧页，交由父层请求；加载后 chapterDirection 驱动相同覆盖动画。
            self.applied.onEdge(direction)
        }
    }

    func stop() {
        stopped = true
        animator?.stopAnimation(true)
        animator = nil
        turn = nil
        pending = nil
        adoption = nil
        pan.isEnabled = false
        clearPages()
    }
}

/// 外层只负责移动与投影，内层裁剪右上/右下圆角，不影响正文排版。
private final class CoverPageSurface: UIViewController {
    private let host: UIHostingController<AnyView>
    private let paper = UIView()
    private var paperSize = CGSize.zero
    private var background: UIColor

    init(content: AnyView, background: UIColor) {
        host = UIHostingController(rootView: content)
        self.background = background
        super.init(nibName: nil, bundle: nil)
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityElementsHidden = true
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOffset = CGSize(width: 4, height: 0)
        view.layer.shadowRadius = 8
        view.layer.shadowOpacity = 0
        paper.backgroundColor = background
        paper.clipsToBounds = true
        paper.layer.cornerCurve = .continuous
        paper.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        paper.frame = view.bounds
        paper.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(paper)
        addChild(host)
        host.view.backgroundColor = background
        host.view.isOpaque = background.cgColor.alpha == 1
        host.view.frame = paper.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        paper.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard paperSize != view.bounds.size else { return }
        paperSize = view.bounds.size
        // 显式投影路径只在尺寸变化时计算；跟手只更新 transform、圆角和透明度。
        view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds,
            byRoundingCorners: [.topRight, .bottomRight], cornerRadii: CGSize(width: 65, height: 65)).cgPath
    }

    #if DEBUG
    var cornerRadius: CGFloat { paper.layer.cornerRadius }
    #endif
    func setRounding(_ radius: CGFloat) { paper.layer.cornerRadius = radius }

    func update(_ content: AnyView, background: UIColor) {
        host.rootView = content
        self.background = background
        paper.backgroundColor = background
        host.view.backgroundColor = background
        host.view.isOpaque = background.cgColor.alpha == 1
    }
}
