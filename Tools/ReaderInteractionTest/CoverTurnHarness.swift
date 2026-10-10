import SwiftUI
import UIKit

struct CoverTurnHarnessView: View {
    @State private var chapter = 0
    @State private var page = 0
    @State private var commits = 0
    @State private var edges = 0
    @State private var revision = 0
    @State private var dark = false
    @State private var bars = 0
    @State private var report = "{}"
    @State private var observer = CoverInspectionObserver()
    private var background: Color { ReadSettings.themes[dark ? 3 : 1].bg }
    private var foreground: Color { ReadSettings.themes[dark ? 3 : 1].fg }

    private func pages(_ id: Int) -> [AnyView] {
        (0..<2).map { n in
            AnyView(PageContentView(page: BookPage(blocks: [.paragraph(text: "第\(id + 1)章，第\(n + 1)页，版本\(revision)。" + String(repeating: "“翻动的页面盖在下一页上。”下一页留在原处，手指移动时边缘圆角跟随。", count: 4), commentCount: 0, commentURL: nil)], startOffset: n * 100),
                fontSize: 19, lineSpacing: 8, fg: foreground, bg: background,
                title: "第\(id + 1)章，第\(n + 1)页，版本\(revision)", pageNumber: n + 1, pageCount: 2,
                onTapComment: { _ in }, safeInsets: EdgeInsets(top: 40, leading: 0, bottom: 15, trailing: 0)))
        }
    }
    private func neighbor(_ id: Int) -> PageTurnChapter? {
        (0..<3).contains(id) ? PageTurnChapter(contentID: "\(id)", pages: pages(id)) : nil
    }
    var body: some View {
        VStack(spacing: 0) {
            PageTurnView(pages: pages(chapter), current: $page, style: .slide, background: UIColor(background),
                onEdge: { _ in edges += 1 }, onTapCenter: { bars += 1 }, contentID: "\(chapter)",
                previousChapter: neighbor(chapter - 1), nextChapter: neighbor(chapter + 1),
                onChapterTransition: { direction, target in chapter += direction; page = target; commits += 1 })
            VStack {
                Text("chapter=\(chapter);page=\(page);commits=\(commits);edges=\(edges);revision=\(revision);bars=\(bars)")
                    .font(.system(size: 9)).accessibilityIdentifier("cover-state")
                HStack {
                    Button("观察") { observer.arm() }.accessibilityIdentifier("cover-arm")
                    Button("检查") { report = observer.snapshot() }.accessibilityIdentifier("cover-inspect")
                    Button("主题") { dark.toggle() }.accessibilityIdentifier("cover-theme")
                    Button("刷新") { revision += 1 }.accessibilityIdentifier("cover-refresh")
                }
                Text("测量").font(.system(size: 7)).accessibilityLabel(report).accessibilityIdentifier("cover-metrics")
            }.frame(height: 85)
        }.background(background).foregroundStyle(foreground).statusBarHidden(true)
    }
}

private final class CoverInspectionObserver: NSObject {
    private weak var controller: ReaderCoverPageTurnController?
    private var gestures: [UIGestureRecognizer] = []
    private var during: [String: Any] = [:]
    private func locate() -> ReaderCoverPageTurnController? {
        func search(_ node: UIViewController) -> ReaderCoverPageTurnController? {
            if let own = node as? ReaderCoverPageTurnController { return own }
            return node.children.lazy.compactMap { search($0) }.first
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        return window?.rootViewController.flatMap { search($0) }
    }
    func arm() {
        gestures.forEach { $0.removeTarget(self, action: #selector(changed(_:))) }
        during = [:]
        controller = locate()
        gestures = controller?.view.gestureRecognizers?.filter { $0 is UIPanGestureRecognizer } ?? []
        gestures.forEach { $0.addTarget(self, action: #selector(changed(_:))) }
    }
    @objc private func changed(_ gesture: UIGestureRecognizer) {
        #if DEBUG
        guard gesture.state == .changed, let controller else { return }
        let value = controller.inspection
        if value["tracking"] as? Bool == true, (value["progress"] as? Double ?? 0) > 0.02 { during = value }
        #endif
    }
    func snapshot() -> String {
        #if DEBUG
        let data: [String: Any] = ["during": during, "current": locate()?.inspection ?? [:]]
        return String(data: try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]), encoding: .utf8)!
        #else
        return "{}"
        #endif
    }
}
