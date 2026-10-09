import SwiftUI
import UIKit

/// 只观察生产容器，不改页号、不强制 layout、不触发完成或提前解锁。
enum AnimationProbe {
    static func controller() -> ReaderPageViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func search(_ controller: UIViewController) -> ReaderPageViewController? {
            if let page = controller as? ReaderPageViewController { return page }
            for child in controller.children { if let page = search(child) { return page } }
            if let presented = controller.presentedViewController { return search(presented) }
            return nil
        }
        for window in windows { if let root = window.rootViewController, let page = search(root) { return page } }
        return nil
    }

    private static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    private static func gray(_ color: UIColor?) -> Int? {
        guard let color else { return nil }
        var white: CGFloat = 0, alpha: CGFloat = 0
        guard color.getWhite(&white, alpha: &alpha) else { return nil }
        return Int((white * 255).rounded())
    }
    private static func backColor(_ page: ReaderPageViewController) -> UIColor? {
        #if DEBUG
        // 生产 API 只读实际提交给 UIKit 且已加载的 back；禁止调用缓存工厂或 loadView。
        return (page.delegate as? PageTurnCoordinator)?.debugBackColor()
        #else
        return nil
        #endif
    }

    static func snapshotMetrics() -> String {
        guard let page = controller() else { return "missing" }
        let fronts = page.viewControllers?.compactMap { $0 as? ReaderPageFace }.filter { !$0.isBack } ?? []
        let front = fronts.first
        let paragraph = front?.viewIfLoaded.map { descendants($0) }?
            .compactMap { $0 as? CommentTextView }.first
        var ink: UIColor?
        if let text = paragraph?.attributedText, text.length > 0 {
            ink = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        }
        let body = (paragraph?.text ?? "none").prefix(90).replacingOccurrences(of: ";", with: "，")
        let idle = (page.delegate as? PageTurnCoordinator)?.isIdle ?? false
        let faceID = front.map { String(ObjectIdentifier($0).hashValue) } ?? "none"
        return "style=\(page.lastChapterAnimation);requests=\(page.chapterAnimationRequests);ends=\(page.chapterAnimationCompletions);idle=\(idle);front=\(front?.pageIndex ?? -1);double=\(page.isDoubleSided);back=\(gray(backColor(page)) ?? -1);frames=\(captureCount);id=\(ObjectIdentifier(page).hashValue);face=\(faceID);generation=\(front?.generation.uuidString ?? "none");fronts=\(fronts.count);paper=\(gray(front?.viewIfLoaded?.backgroundColor) ?? -1);ink=\(gray(ink) ?? -1);body=\(body);recording=\(recorder != nil);backSamples=\(backSamples);backMin=\(backSamples == 0 ? -1 : backMin);backMax=\(backSamples == 0 ? -1 : backMax);backAlpha=\(backSamples == 0 ? -1 : backAlpha);captureError=\(captureError)"
    }

    private static var recorder: Recorder?
    private(set) static var captureCount = 0
    private static var backSamples = 0
    private static var backMin = 255
    private static var backMax = 0
    private static var backAlpha = 255
    private static var captureError = "none"
    static func arm() {
        recorder?.stop()
        captureCount = 0
        backSamples = 0
        backMin = 255
        backMax = 0
        backAlpha = 255
        captureError = "none"
        guard let page = controller() else { return }
        #if DEBUG
        page.onChapterAnimationStarted = { [weak page] in
            guard let page else { return }
            DispatchQueue.main.async { AnimationProbe.recorder = Recorder(page: page) }
        }
        #endif
    }

    private final class Recorder: NSObject {
        weak var page: ReaderPageViewController?
        var link: CADisplayLink?
        var tick = 0
        init(page: ReaderPageViewController) {
            self.page = page
            super.init()
            link = CADisplayLink(target: self, selector: #selector(frame))
            link?.add(to: .main, forMode: .common)
        }
        func stop() {
            link?.invalidate()
            link = nil
            AnimationProbe.recorder = nil
        }
        @objc private func frame() {
            tick += 1
            guard let page else { stop(); return }
            let animating = page.chapterAnimationRequests > page.chapterAnimationCompletions
            if animating, let color = AnimationProbe.backColor(page), let white = AnimationProbe.gray(color) {
                AnimationProbe.backSamples += 1
                AnimationProbe.backMin = min(AnimationProbe.backMin, white)
                AnimationProbe.backMax = max(AnimationProbe.backMax, white)
                AnimationProbe.backAlpha = min(AnimationProbe.backAlpha, Int((color.cgColor.alpha * 255).rounded()))
            }
            if animating, [3, 8, 15].contains(tick), let window = page.viewIfLoaded?.window {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
                if let data = image.pngData() {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    do {
                        try data.write(to: folder.appendingPathComponent("turn-frame-\(tick).png"), options: .atomic)
                        AnimationProbe.captureCount += 1
                    } catch { AnimationProbe.captureError = String(describing: error) }
                }
            }
            if (!animating && (page.delegate as? PageTurnCoordinator)?.isIdle == true) || tick >= 120 { stop() }
        }
    }
}

/// 指标在独立子树更新，不能因检查按钮/轮询而重建父 Harness 的 pages，掩盖旧页刷新错误。
struct AnimationProbeControls: View {
    @State private var metrics = "none"
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Button("检查动画", action: refresh).accessibilityIdentifier("inspect-animation")
                Button("记录动画") { AnimationProbe.arm(); refresh() }.accessibilityIdentifier("arm-animation")
            }.font(.caption)
            Text(metrics).font(.system(size: 6)).lineLimit(1).minimumScaleFactor(0.2)
                .accessibilityIdentifier("animation-metrics")
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }
    private func refresh() {
        let value = AnimationProbe.snapshotMetrics()
        if metrics != value { metrics = value }
    }
}
