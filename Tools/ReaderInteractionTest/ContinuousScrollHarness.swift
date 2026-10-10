import SwiftUI
import UIKit

struct ContinuousScrollHarnessView: View {
    @State private var ids = [1, 2]
    @State private var request: ReaderScrollRequest? = ReaderScrollRequest(id: UUID(), chapter: 1, permille: 0)
    @State private var chapter = 1
    @State private var position = 0
    @State private var changes = 0
    @State private var settlements = 0
    @State private var savedChapter = -1
    @State private var savedPosition = -1
    @State private var inspected = "{}"
    @State private var font: CGFloat = 19
    private var short: Bool { ProcessInfo.processInfo.arguments.contains("--continuous-short") }

    var body: some View {
        VStack(spacing: 0) {
            ReaderContinuousScrollView(chapters: ids.map { id in
                ReaderScrollChapter(id: id, revision: "\(id)", content: AnyView(content(id)))
            }, request: request, layoutID: "\(font)", background: .white,
                onPosition: { value, permille in
                    // Deliberately invalidate SwiftUI during a drag; stable hosts must stay cached.
                    chapter = value; position = permille; changes += 1
                }, onApproachEdge: { _ in }, onSettled: { value, permille in
                    savedChapter = value; savedPosition = permille; settlements += 1
                })
            VStack(spacing: 3) {
                Text("chapter=\(chapter);position=\(position);changes=\(changes);ids=\(ids.map(String.init).joined(separator: ","))")
                    .font(.system(size: 9)).accessibilityIdentifier("continuous-state")
                Text("settlements=\(settlements);savedChapter=\(savedChapter);savedPosition=\(savedPosition)")
                    .font(.system(size: 8)).accessibilityIdentifier("continuous-settled")
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

    private func paragraphText(_ paragraph: Int) -> String {
        let dialogue = [
            "「先别急着翻页，先看看这一段。」他说。‘风从江面来，灯影落在水上。’",
            "她答道：“我记得那句‘路远且长，仍要向前’。——今晚也一样。”",
            "“真的吗？”他问，“连同 AVATAR、office 和 é 这样的混排，也要保持原文。”"
        ][paragraph % 3]
        let body = "前后章节保留在同一滚动页面，阅读时顺滑衔接。"
        if short { return body }
        return body + String(repeating: dialogue + "春江花月夜山川风雨天地。", count: 3)
    }

    private func content(_ id: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ChapterTitleView(title: "第\(id)章 连续阅读", fontSize: font, color: .black)
                .accessibilityIdentifier("scroll-title-\(id)")
                .padding(.top, 24).padding(.bottom, 18)
            ForEach(0..<(short ? 1 : 10), id: \.self) { paragraph in
                InlineCommentParagraph(text: paragraphText(paragraph),
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
    // Inspect existing TextKit glyphs in visible production paragraphs without calling sizeThatFits.
    // Mixed Latin paragraphs are deliberately excluded from the CJK column invariant.
    private static func alignment(in scroll: UIScrollView) -> [String: Any] {
        var paragraphs = 0, glyphs = 0, quotes = 0
        var gridError: CGFloat = 0
        let quoteCharacters = Set("‘’“”「」")
        func visit(_ view: UIView) {
            if let text = view as? CommentTextView,
               text.convert(text.bounds, to: scroll).intersects(scroll.bounds) {
                let source = text.textStorage.string
                guard text.bounds.width > 0, !source.isEmpty,
                      source.unicodeScalars.allSatisfy({ $0.value > 0x7f }) else { return }
                let manager = text.layoutManager
                let font = (text.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)?.pointSize ?? 19
                let grid = ReaderTextLayout.metrics(fontSize: font, width: text.bounds.width)
                let string = source as NSString
                manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: text.textContainer)) {
                    rect, _, _, range, _ in
                    for glyph in range.location..<NSMaxRange(range) {
                        let x = rect.minX + manager.location(forGlyphAt: glyph).x
                        gridError = max(gridError, abs(x - (x / grid.cellWidth).rounded() * grid.cellWidth))
                        let index = manager.characterIndexForGlyph(at: glyph)
                        let character = string.substring(with: string.rangeOfComposedCharacterSequence(at: index))
                        if character.contains(where: { quoteCharacters.contains($0) }) { quotes += 1 }
                        glyphs += 1
                    }
                }
                paragraphs += 1
            }
            for child in view.subviews { visit(child) }
        }
        visit(scroll)
        return ["paragraphs": paragraphs, "glyphs": glyphs, "quotes": quotes, "gridError": Double(gridError)]
    }

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
        var report: [String: Any] = ["frames": frames, "offset": Double(scroll.contentOffset.y),
            "viewport": Double(scroll.bounds.height), "content": Double(scroll.contentSize.height),
            "native": type(of: scroll) == UIScrollView.self,
            "idle": !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating,
            "alignment": alignment(in: scroll)]
        #if DEBUG
        // Read production work counters on demand; never estimate work from progress callbacks.
        report["measurementCount"] = reader.measurementCount
        report["contentInstallCount"] = reader.contentInstallCount
        #endif
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
