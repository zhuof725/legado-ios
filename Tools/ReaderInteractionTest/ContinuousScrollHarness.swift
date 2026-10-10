import SwiftUI
import UIKit

struct ContinuousScrollHarnessView: View {
    @State private var ids = [1, 2]
    @State private var request: ReaderScrollRequest? = ReaderScrollRequest(id: UUID(), chapter: 1, permille: 0)
    @State private var chapter = 1
    @State private var position = 0
    @State private var changes = 0
    @State private var inspected = "{}"
    @State private var font: CGFloat = 19
    private var short: Bool { ProcessInfo.processInfo.arguments.contains("--continuous-short") }

    var body: some View {
        VStack(spacing: 0) {
            ReaderContinuousScrollView(chapters: ids.map { id in
                ReaderScrollChapter(id: id, revision: "\(id)", content: AnyView(content(id)))
            }, request: request, layoutID: "\(font)", background: .white,
                onPosition: { value, permille in
                    chapter = value; position = permille; changes += 1
                }, onApproachEdge: { _ in })
            VStack(spacing: 3) {
                Text("chapter=\(chapter);position=\(position);changes=\(changes);ids=\(ids.map(String.init).joined(separator: ","))")
                    .font(.system(size: 9)).accessibilityIdentifier("continuous-state")
                HStack {
                    Button("章末") { request = ReaderScrollRequest(id: UUID(), chapter: 1, permille: 1000) }
                        .accessibilityIdentifier("scroll-boundary")
                    Button("前插") { if !ids.contains(0) { ids.insert(0, at: 0) } }
                        .accessibilityIdentifier("scroll-prepend")
                    Button("追加") { if !ids.contains(3) { ids.append(3) } }
                        .accessibilityIdentifier("scroll-append")
                    Button("裁剪") { ids.removeAll { $0 == 0 } }
                        .accessibilityIdentifier("scroll-trim")
                    Button("恢复") { request = ReaderScrollRequest(id: UUID(), chapter: 2, permille: 450) }
                        .accessibilityIdentifier("scroll-restore")
                    Button("检查") { inspected = ContinuousScrollInspection.snapshot() }
                        .accessibilityIdentifier("scroll-inspect")
                }.font(.caption)
                Text("测量").font(.system(size: 6)).accessibilityLabel(inspected)
                    .accessibilityIdentifier("continuous-metrics")
            }.frame(height: 80).background(Color.white)
        }.statusBarHidden(true)
    }

    private func content(_ id: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ChapterTitleView(title: "第\(id)章 连续阅读", fontSize: font, color: .black)
                .accessibilityIdentifier("scroll-title-\(id)")
                .padding(.top, 24).padding(.bottom, 18)
            ForEach(0..<(short ? 1 : 7), id: \.self) { paragraph in
                InlineCommentParagraph(text: "第\(id)章段落\(paragraph)。" + String(repeating: "前后章节保留在同一滚动页面，阅读时顺滑衔接。", count: short ? 1 : 3),
                    count: 0, fontSize: font, lineSpacing: 8, color: .black, onTap: {})
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("第\(id)章结束").font(.system(size: font)).accessibilityIdentifier("scroll-tail-\(id)")
        }
        .padding(.horizontal, 20).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum ContinuousScrollInspection {
    static func snapshot() -> String {
        func controller(_ value: UIViewController) -> ReaderContinuousScrollController? {
            if let own = value as? ReaderContinuousScrollController { return own }
            return value.children.lazy.compactMap { controller($0) }.first
        }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard let root = window?.rootViewController, let reader = controller(root),
              let scroll = reader.view.subviews.compactMap({ $0 as? UIScrollView }).first else { return "{}" }
        // UIHosting children are real chapter views; compare a retained chapter's origin in the viewport.
        let frames = reader.children.compactMap { child -> [String: Any]? in
            guard child.view.superview === scroll else { return nil }
            func title(_ view: UIView) -> String? {
                if let label = view as? UILabel, let text = label.text, text.hasPrefix("第"), text.contains("连续阅读") { return text }
                return view.subviews.lazy.compactMap { title($0) }.first
            }
            guard let title = title(child.view) else { return nil }
            return ["title": title, "y": Double(child.view.frame.minY - scroll.contentOffset.y),
                    "height": Double(child.view.frame.height)]
        }
        let report: [String: Any] = ["frames": frames, "offset": Double(scroll.contentOffset.y),
            "viewport": Double(scroll.bounds.height), "content": Double(scroll.contentSize.height),
            "native": type(of: scroll) == UIScrollView.self]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
