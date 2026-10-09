import UIKit

/// 由 XCUITest 按钮调用，只观察生产容器，不直接改页号或触发完成回调。
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

    static func snapshotMetrics() -> String {
        guard let page = controller() else { return "missing" }
        let front = page.viewControllers?.compactMap { $0 as? ReaderPageFace }.first { !$0.isBack }
        let isIdle = (page.delegate as? PageTurnCoordinator)?.isIdle ?? false
        #if DEBUG
        let color = (page.delegate as? PageTurnCoordinator)?.debugBackColor()
        #else
        let color: UIColor? = nil
        #endif
        var white: CGFloat = 0, alpha: CGFloat = 0
        color?.getWhite(&white, alpha: &alpha)
        let frameCount = captureCount
        return "style=\(page.lastChapterAnimation);requests=\(page.chapterAnimationRequests);ends=\(page.chapterAnimationCompletions);idle=\(isIdle);front=\(front?.pageIndex ?? -1);double=\(page.isDoubleSided);back=\(Int(white * 255));frames=\(frameCount);id=\(ObjectIdentifier(page).hashValue)"
    }

    private static var recorder: Recorder?
    private(set) static var captureCount = 0
    static func arm() {
        guard let page = controller() else { return }
        captureCount = 0
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
        @objc private func frame() {
            tick += 1
            if [3, 8, 15].contains(tick), let page, let window = page.view.window {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
                if let data = image.pngData() {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? data.write(to: folder.appendingPathComponent("turn-frame-\(tick).png"), options: .atomic)
                    AnimationProbe.captureCount += 1
                }
            }
            if tick >= 16 { link?.invalidate(); link = nil; AnimationProbe.recorder = nil }
        }
    }
}
