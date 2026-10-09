import SwiftUI
import UIKit

/// 放在阅读 ScrollView 内容的 background。只观察现有滚动手势，不安装抢占点击的手势。
struct ReaderScrollBoundaryObserver: UIViewRepresentable {
    let chapterID: String
    let isEnabled: Bool
    let onNext: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.onAttach = { [weak coordinator = context.coordinator] view in coordinator?.attach(from: view) }
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        context.coordinator.update(self)
        context.coordinator.attach(from: view)
    }

    static func dismantleUIView(_ view: Probe, coordinator: Coordinator) {
        view.onAttach = nil
        coordinator.detach()
    }

    final class Probe: UIView {
        var onAttach: ((UIView) -> Void)?
        override func didMoveToSuperview() { super.didMoveToSuperview(); findScrollView() }
        override func didMoveToWindow() { super.didMoveToWindow(); findScrollView() }
        private func findScrollView() {
            onAttach?(self)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onAttach?(self)
            }
        }
    }

    final class Coordinator: NSObject {
        private var parent: ReaderScrollBoundaryObserver
        private weak var scrollView: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var intent = ScrollChapterAdvance()
        private var originalBounce = false

        init(_ parent: ReaderScrollBoundaryObserver) { self.parent = parent }

        func update(_ next: ReaderScrollBoundaryObserver) {
            if next.chapterID != parent.chapterID {
                intent.reset()
                // 新章重新从顶部布局，先终止旧章的惯性，避免它把新正文推走。
                if let scroll = scrollView, scroll.isDecelerating {
                    scroll.setContentOffset(scroll.contentOffset, animated: false)
                }
            }
            if !next.isEnabled { intent.reset() }
            parent = next
        }

        func attach(from view: UIView) {
            var ancestor = view.superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView {
                    guard scroll !== scrollView else { return }
                    detach()
                    scrollView = scroll
                    originalBounce = scroll.alwaysBounceVertical
                    // 即使短章不足一屏，也能用一次向上手势进入下一章。
                    scroll.alwaysBounceVertical = true
                    scroll.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
                    offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                        guard scroll.isDecelerating else { return }
                        self?.checkBottom()
                    }
                    return
                }
                ancestor = candidate.superview
            }
        }

        func detach() {
            offsetObservation?.invalidate()
            offsetObservation = nil
            if let scroll = scrollView {
                scroll.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
                scroll.alwaysBounceVertical = originalBounce
            }
            scrollView = nil
            intent.reset()
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                intent.begin(chapterID: parent.chapterID, enabled: parent.isEnabled)
            case .ended:
                let delta = pan.translation(in: pan.view)
                intent.end(horizontal: Double(delta.x), vertical: Double(delta.y), cancelled: false)
                // 不在 UIKit 手势分发或 KVO 回调中替换 SwiftUI 阅读页面。
                DispatchQueue.main.async { [weak self] in self?.checkBottom() }
            case .cancelled, .failed:
                intent.reset()
            default:
                break
            }
        }

        private func checkBottom() {
            guard let scroll = scrollView else { return }
            let minimum = -scroll.adjustedContentInset.top
            let bottom = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            guard intent.shouldAdvance(chapterID: parent.chapterID, enabled: parent.isEnabled,
                                       atBottom: scroll.contentOffset.y >= bottom - 2) else { return }
            let chapterID = parent.chapterID
            // 消费手势后只发一次；此章的惯性/回弹不能接着触发下一章。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isEnabled, self.parent.chapterID == chapterID else { return }
                self.parent.onNext()
            }
        }
    }
}
