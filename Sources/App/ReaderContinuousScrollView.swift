import SwiftUI
import UIKit

struct ReaderScrollChapter {
    let id: Int
    let revision: String
    let content: AnyView
    /// 只改变颜色/边界提示时刷新视图，不使已测量正文高度失效。
    var appearanceID: String = ""
}

struct ReaderScrollRequest: Equatable {
    let id: UUID
    let chapter: Int
    let permille: Int
}

/// 所有已加载章节共享一个 UIScrollView。追加/前插只改内容范围，不重新创建滚动视图。
struct ReaderContinuousScrollView: UIViewControllerRepresentable {
    let chapters: [ReaderScrollChapter]
    let request: ReaderScrollRequest?
    let layoutID: String
    let background: UIColor
    let onPosition: (_ chapter: Int, _ permille: Int) -> Void
    let onApproachEdge: (_ direction: Int) -> Void
    var onSettled: (_ chapter: Int, _ permille: Int) -> Void = { _, _ in }

    func makeUIViewController(context: Context) -> ReaderContinuousScrollController {
        let controller = ReaderContinuousScrollController()
        controller.update(self)
        return controller
    }
    func updateUIViewController(_ controller: ReaderContinuousScrollController, context: Context) {
        controller.update(self)
    }
}

private struct ScrollChapterHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MeasuredScrollChapter: View {
    let content: AnyView
    let onHeight: (CGFloat) -> Void
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ScrollChapterHeightKey.self, value: geometry.size.height)
            })
            .onPreferenceChange(ScrollChapterHeightKey.self, perform: onHeight)
    }
}

final class ReaderContinuousScrollController: UIViewController, UIScrollViewDelegate {
    private final class Entry {
        let host: UIHostingController<AnyView>
        var revision: String
        var appearanceID: String
        var measuredWidth: CGFloat = 0
        var height: CGFloat = 0
        var needsMeasurement = true
        var frame = CGRect.zero
        init(host: UIHostingController<AnyView>, revision: String, appearanceID: String) {
            self.host = host
            self.revision = revision
            self.appearanceID = appearanceID
        }
    }
    private struct Anchor {
        let id: Int
        let localY: CGFloat
        let fraction: CGFloat
    }
    private let scroll = UIScrollView()
    private var model: ReaderContinuousScrollView?
    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []
    private var layoutID = ""
    private var dirty = true
    private var layingOut = false
    private var pendingAnchor: Anchor?
    private var reflow = false
    private var lastSize = CGSize.zero
    private var appliedRequest: UUID?
    private var userScrolling = false
    private var publishQueued = false
    private var callbacksGeneration = UUID()
    private var lastPosition: String?
    private var edgeSent: [Int: Int] = [:]
    private var measuredChanges: [Int: CGFloat] = [:]
    private var heightUpdateQueued = false
    private var deferredModel: ReaderContinuousScrollView?
    #if DEBUG
    private(set) var measurementCount = 0
    private(set) var contentInstallCount = 0
    #endif

    override func loadView() {
        view = UIView()
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "continuous-reader-scroll"
        view.addSubview(scroll)
    }

    func update(_ next: ReaderContinuousScrollView) {
        loadViewIfNeeded()
        let ids = next.chapters.map { $0.id }
        let layoutChanged = next.layoutID != layoutID
        let changed = ids != order || layoutChanged || next.chapters.contains {
            entries[$0.id]?.revision != $0.revision || entries[$0.id]?.appearanceID != $0.appearanceID
        }
        let newRequest = next.request?.id != model?.request?.id
        // 网络返回/状态提示不抢占手指与惯性所在的主线程布局；结束本次滚动后合并更新。
        if userScrolling && changed && !newRequest {
            deferredModel = next
            return
        }
        deferredModel = nil
        if changed && pendingAnchor == nil { pendingAnchor = anchor() }
        reflow = reflow || layoutChanged
        model = next
        view.backgroundColor = next.background
        scroll.backgroundColor = next.background
        if newRequest {
            callbacksGeneration = UUID()
            userScrolling = false
            lastPosition = nil
        }
        if changed {
            let kept = Set(ids)
            for id in Array(entries.keys) where !kept.contains(id) {
                guard let entry = entries.removeValue(forKey: id) else { continue }
                entry.host.willMove(toParent: nil)
                entry.host.view.removeFromSuperview()
                entry.host.removeFromParent()
            }
            for chapter in next.chapters {
                let existing = entries[chapter.id]
                let contentChanged = existing?.revision != chapter.revision || layoutChanged
                let appearanceChanged = existing?.appearanceID != chapter.appearanceID
                guard contentChanged || appearanceChanged else { continue }
                let root = AnyView(MeasuredScrollChapter(content: chapter.content) { [weak self] height in
                    self?.heightChanged(chapter.id, revision: chapter.revision, height: height)
                })
                #if DEBUG
                contentInstallCount += 1
                #endif
                if let entry = existing {
                    entry.revision = chapter.revision
                    entry.appearanceID = chapter.appearanceID
                    entry.needsMeasurement = entry.needsMeasurement || contentChanged
                    entry.host.rootView = root
                } else {
                    let host = UIHostingController(rootView: root)
                    if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
                    addChild(host)
                    scroll.addSubview(host.view)
                    host.didMove(toParent: self)
                    entries[chapter.id] = Entry(host: host, revision: chapter.revision, appearanceID: chapter.appearanceID)
                }
                entries[chapter.id]?.host.view.backgroundColor = next.background
            }
            order = ids
            layoutID = next.layoutID
            dirty = true
        }
        if changed || newRequest { view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !layingOut, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let requestPending = model?.request.map { $0.id != appliedRequest && entries[$0.chapter] != nil } ?? false
        guard dirty || view.bounds.size != lastSize || requestPending else { return }
        if view.bounds.size != lastSize {
            if pendingAnchor == nil { pendingAnchor = anchor() }
            reflow = reflow || lastSize.width != view.bounds.width
            dirty = true
        }
        layingOut = true
        let saved = pendingAnchor ?? anchor()
        scroll.frame = view.bounds
        let size = scroll.bounds.size
        if dirty {
            var y: CGFloat = 0
            for id in order {
                guard let entry = entries[id] else { continue }
                if entry.needsMeasurement || entry.measuredWidth != size.width {
                    #if DEBUG
                    measurementCount += 1
                    #endif
                    entry.height = max(ceil(entry.host.sizeThatFits(in: CGSize(width: size.width,
                        height: CGFloat.greatestFiniteMagnitude)).height), 1)
                    entry.measuredWidth = size.width
                    entry.needsMeasurement = false
                }
                entry.frame = CGRect(x: 0, y: y, width: size.width, height: entry.height)
                if entry.host.view.frame != entry.frame { entry.host.view.frame = entry.frame }
                y += entry.height
            }
            // 尾部留白只在短末章之后，不插在章节之间；保证该章可恢复到视口顶端。
            let lastHeight = order.last.flatMap { entries[$0]?.frame.height } ?? size.height
            scroll.contentSize = CGSize(width: size.width, height: y + max(size.height - lastHeight, 0))
            dirty = false
        }
        var requested = false
        if let request = model?.request, request.id != appliedRequest, let entry = entries[request.chapter] {
            let extent = max(entry.frame.height - size.height, 0)
            setOffset(entry.frame.minY + extent * CGFloat(min(max(request.permille, 0), 1000)) / 1000)
            appliedRequest = request.id
            requested = true
            userScrolling = false
        } else if let saved, let entry = entries[saved.id] {
            let local = reflow ? saved.fraction * entry.frame.height : saved.localY
            setOffset(entry.frame.minY + local)
        }
        pendingAnchor = nil
        reflow = false
        lastSize = size
        layingOut = false
        // layout / 请求定位不产生阅读进度；但可预读附近内容以填满屏幕。
        checkEdges()
        if !requested && userScrolling { queuePosition() }
    }

    private func setOffset(_ y: CGFloat) {
        let value = min(max(y, 0), max(scroll.contentSize.height - scroll.bounds.height, 0))
        guard abs(value - scroll.contentOffset.y) > 0.25 else { return }
        // 插入/裁剪章节时只补偿内容原点，不改原生 pan / deceleration。
        scroll.contentOffset = CGPoint(x: 0, y: value)
    }

    private func anchor() -> Anchor? {
        let y = max(scroll.contentOffset.y, 0)
        guard let id = order.first(where: { (entries[$0]?.frame.maxY ?? 0) > y + 0.5 }) ?? order.last,
              let entry = entries[id], entry.frame.height > 0 else { return nil }
        let local = max(y - entry.frame.minY, 0)
        return Anchor(id: id, localY: local, fraction: local / entry.frame.height)
    }

    private func heightChanged(_ id: Int, revision: String, height: CGFloat) {
        guard height.isFinite, height > 0, let entry = entries[id], entry.revision == revision,
              abs(ceil(height) - entry.frame.height) > 1 else { return }
        measuredChanges[id] = height
        guard !heightUpdateQueued else { return }
        heightUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.heightUpdateQueued = false
            guard !self.userScrolling else { return }
            self.applyMeasuredHeights()
        }
    }

    private func applyMeasuredHeights() {
        let changes = measuredChanges
        measuredChanges.removeAll()
        let changed = changes.filter { id, height in
            guard let entry = entries[id], !entry.needsMeasurement else { return false }
            return abs(ceil(height) - entry.frame.height) > 1
        }
        guard !changed.isEmpty else { return }
        if pendingAnchor == nil { pendingAnchor = anchor() }
        for (id, height) in changed { entries[id]?.height = ceil(height) }
        dirty = true
        view.setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolling = true
        callbacksGeneration = UUID()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut else { return }
        if userScrolling { queuePosition() }
        checkEdges()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        queuePosition()
        if !decelerate { finishUserScroll() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        queuePosition()
        finishUserScroll()
    }
    private func finishUserScroll() {
        let expected = callbacksGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callbacksGeneration == expected else { return }
            self.userScrolling = false
            if let position = self.currentPosition() { self.model?.onSettled(position.chapter, position.permille) }
            if let deferred = self.deferredModel { self.update(deferred) }
            self.applyMeasuredHeights()
        }
    }
    private func currentPosition() -> (chapter: Int, permille: Int)? {
        guard let anchor = anchor(), let entry = entries[anchor.id] else { return nil }
        let extent = max(entry.frame.height - scroll.bounds.height, 1)
        return (anchor.id, Int(min(max(anchor.localY / extent, 0), 1) * 1000))
    }
    private func queuePosition() {
        guard userScrolling, !publishQueued else { return }
        publishQueued = true
        let expected = callbacksGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishQueued = false
            guard self.callbacksGeneration == expected, let anchor = self.anchor(),
                  let entry = self.entries[anchor.id], let model = self.model else { return }
            let extent = max(entry.frame.height - self.scroll.bounds.height, 1)
            let position = Int(min(max(anchor.localY / extent, 0), 1) * 1000)
            let key = "\(anchor.id):\(position)"
            guard self.lastPosition != key else { return }
            self.lastPosition = key
            model.onPosition(anchor.id, position)
        }
    }

    private func checkEdges() {
        guard !layingOut, scroll.bounds.height > 0, !order.isEmpty, let model else { return }
        if let request = model.request, appliedRequest != request.id { return }
        let threshold = scroll.bounds.height
        let y = max(scroll.contentOffset.y, 0)
        for direction in [-1, 1] {
            guard let id = direction > 0 ? order.last : order.first else { continue }
            let near = direction > 0
                ? scroll.contentSize.height - (y + scroll.bounds.height) <= threshold
                : y <= threshold
            if !near { edgeSent[direction] = nil; continue }
            guard edgeSent[direction] != id else { continue }
            edgeSent[direction] = id
            DispatchQueue.main.async { [weak self] in
                guard let self, self.edgeSent[direction] == id,
                      (direction > 0 ? self.order.last : self.order.first) == id else { return }
                self.model?.onApproachEdge(direction)
            }
        }
    }
}
