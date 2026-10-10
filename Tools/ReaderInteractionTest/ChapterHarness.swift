import SwiftUI
import UIKit

/// 离线提供真实相邻章；slow 保留缺少预加载时的异步 onEdge 回退。
struct ChapterHarnessView: View {
    let mode: String
    @State private var chapter = 0
    @State private var page = 0
    @State private var loading = false
    @State private var edgeCount = 0
    @State private var bars = 0
    @State private var chapterDirection = 0
    @State private var edgeLocked = false
    @State private var revision = 0
    @State private var nativeInfo = "none"
    @State private var slowLoads = 0
    @State private var cachedLoads = 0
    @State private var commits = 0
    @State private var invalidCommits = 0
    @State private var lastCommit = "none"
    @State private var dark = false
    @State private var dragObservation = NativeDragObservation()
    private var theme: (bg: Color, fg: Color, name: String) { ReadSettings.themes[dark ? 3 : 1] }
    private var background: UIColor { UIColor(theme.bg) }
    private var foreground: Color { theme.fg }
    private var isPaged: Bool { mode != "scroll" && mode != "short" }
    private var loadMode: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--chapter-load=") }
            .map { String($0.dropFirst("--chapter-load=".count)) } ?? "cached"
    }
    private var revisionSuffix: String { revision == 0 ? "" : " · 更新\(revision)" }

    private func pages(in chapter: Int) -> [AnyView] {
        (0..<2).map { n in
            AnyView(PageContentView(
                page: BookPage(blocks: [.paragraph(text: "第\(chapter + 1)章，第\(n + 1)页。正文版本\(revision)。" + String(repeating: "继续向左翻阅，章末自动下一章。", count: n == 0 ? 6 : 1), commentCount: 0, commentURL: nil)], startOffset: n * 100),
                fontSize: 19, lineSpacing: 8, fg: foreground, bg: Color(background),
                title: "第\(chapter + 1)章，第\(n + 1)页" + revisionSuffix, pageNumber: n + 1, pageCount: 2,
                onTapComment: { _ in }, safeInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                showsChapterTitle: true).ignoresSafeArea())
        }
    }

    private func preparedChapter(_ target: Int) -> PageTurnChapter? {
        guard loadMode == "cached", (0..<3).contains(target) else { return nil }
        return PageTurnChapter(contentID: String(target), pages: pages(in: target))
    }

    var body: some View {
        let previous = preparedChapter(chapter - 1)
        let next = preparedChapter(chapter + 1)
        return VStack(spacing: 0) {
            Group {
                if mode == "scroll" || mode == "short" {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 8) {
                                Color.clear.frame(height: 1).id("top")
                                ForEach(0..<(mode == "short" ? 2 : 18), id: \.self) { i in
                                    Text("第\(chapter + 1)章 段落\(i)")
                                        .frame(maxWidth: .infinity).frame(height: 80)
                                }
                                Text("本章结束").id("bottom")
                            }
                            .background {
                                ReaderScrollBoundaryObserver(chapterID: String(chapter),
                                    isEnabled: !loading && chapter < 2,
                                    onNext: { advance(1) })
                            }
                        }
                        .id(chapter)
                        .overlay(alignment: .topLeading) {
                            Button("定位章末") { proxy.scrollTo("bottom", anchor: .bottom) }
                                .accessibilityIdentifier("program-bottom")
                        }
                    }
                } else {
                    PageTurnView(pages: pages(in: chapter), current: $page, style: mode.hasPrefix("curl") ? .curl : .slide,
                                 background: background, onEdge: advance, onTapCenter: { bars += 1 },
                                 contentID: "\(chapter)", chapterDirection: chapterDirection,
                                 onContentTransitionCompleted: { chapterDirection = 0; edgeLocked = false },
                                 previousChapter: previous, nextChapter: next,
                                 onChapterTransition: { direction, index in
                                     commitChapter(direction, index, prepared: direction < 0 ? previous : next)
                                 })
                }
            }
            .overlay {
                if loading { Color.black.opacity(0.02).contentShape(Rectangle()).overlay(ProgressView()) }
            }
            VStack(spacing: 2) {
                Text("chapter=\(chapter);page=\(page);edges=\(edgeCount);loading=\(loading);bars=\(bars);locked=\(edgeLocked);contentID=\(chapter);count=2;revision=\(revision);load=\(loadMode);slow=\(slowLoads);cached=\(cachedLoads);commits=\(commits);invalid=\(invalidCommits);last=\(lastCommit);theme=\(dark ? "dark" : "light")")
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.3)
                    .accessibilityIdentifier("chapter-state")
                HStack {
                    // 不改 contentID、页数、current，也不手动调用生产完成回调。
                    Button("刷新正文") { revision += 1 }.accessibilityIdentifier("refresh-content")
                    Button("切换主题") { dark.toggle() }.accessibilityIdentifier("toggle-theme")
                    Button("观察手势") {
                        dragObservation.arm(background: background, revision: revision) {
                            "duringChapter=\(chapter);duringPage=\(page);duringEdges=\(edgeCount);duringCommits=\(commits);duringLoading=\(loading)"
                        }
                    }.accessibilityIdentifier("arm-native-drag")
                    Button("检查原生") {
                        nativeInfo = NativeReaderInspection.snapshot(background: background, revision: revision,
                            bodyPrefix: "第\(chapter + 1)章，第\(page + 1)页。正文版本\(revision)。")
                            + ";" + dragObservation.snapshot
                    }.accessibilityIdentifier("inspect-native")
                }.font(.caption).disabled(loading || edgeLocked)
                Text("原生检查").font(.system(size: 7)).accessibilityLabel(nativeInfo)
                    .accessibilityIdentifier("native-info")
            }.frame(height: 88).background(Color(background)).foregroundStyle(foreground)
        }
        .background(Color(background))
        .preferredColorScheme(dark ? .dark : .light)
        .statusBarHidden(true)
    }

    private func commitChapter(_ direction: Int, _ pageIndex: Int, prepared: PageTurnChapter?) {
        commits += 1
        lastCommit = "\(direction):\(pageIndex)"
        guard isPaged, loadMode == "cached", !loading, !edgeLocked, abs(direction) == 1,
              let prepared, let target = Int(prepared.contentID), target == chapter + direction,
              (0..<3).contains(target), prepared.pages.indices.contains(pageIndex),
              pageIndex == (direction > 0 ? 0 : prepared.pages.count - 1) else {
            invalidCommits += 1
            return
        }
        // UIKit 已经把真正邻页翻到前台；父层只认领匹配的 contentID/current，不再启动切章动画。
        cachedLoads += 1
        chapter = target
        page = pageIndex
        chapterDirection = 0
    }

    private func advance(_ direction: Int) {
        guard !loading, !edgeLocked else { return }
        let target = chapter + direction
        guard (0..<3).contains(target) else { return }
        edgeCount += 1
        // 已预加载的分页章不允许偷偷退回同步 onEdge；保留计数，让测试直接报错。
        guard !isPaged || loadMode != "cached" else { return }
        loading = true
        chapterDirection = isPaged ? direction : 0
        edgeLocked = chapterDirection != 0
        if loadMode == "cached" {
            cachedLoads += 1
            // 真正同步返回，不用 Task/async 冒充缓存命中路径。
            applyChapter(target, direction: direction)
        } else {
            slowLoads += 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                applyChapter(target, direction: direction)
            }
        }
    }

    private func applyChapter(_ target: Int, direction: Int) {
        chapter = target
        page = direction > 0 ? 0 : 1
        loading = false
        // edgeLocked 只由生产 onContentTransitionCompleted 解除。
    }
}

/// 只查询公开 dataSource/children 和生产 ReaderPageHost，不改 current、不手动结束转场。
private enum NativeReaderInspection {
    static func pageController() -> UIPageViewController? {
        func search(_ node: UIViewController) -> UIPageViewController? {
            if let page = node as? UIPageViewController { return page }
            return node.children.lazy.compactMap { search($0) }.first
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow)?.rootViewController.flatMap { search($0) }
    }

    private static func front(_ node: UIViewController) -> ReaderPageHost? {
        if let host = node as? ReaderPageHost { return host }
        return node.children.lazy.compactMap { front($0) }.first
    }

    private static func paragraph(_ node: UIView) -> UITextView? {
        if let text = node as? CommentTextView { return text }
        return node.subviews.lazy.compactMap { paragraph($0) }.first
    }

    static func snapshot(background: UIColor, revision: Int, bodyPrefix: String) -> String {
        guard let page = pageController(), let source = page.dataSource,
              let shown = page.viewControllers?.first, let host = front(shown),
              let text = paragraph(host.view), let attributed = text.attributedText, attributed.length > 0,
              let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont else { return "missing" }

        // 双面 curl 的 front → back → front；最多查三次，遇环即停，不猜 UIKit 私有类名。
        func neighbor(_ forward: Bool) -> (face: ReaderPageHost?, backs: [UIViewController], valid: Bool) {
            var cursor = shown
            var seen: Set<ObjectIdentifier> = [ObjectIdentifier(shown)]
            var backs: [UIViewController] = []
            for _ in 0..<3 {
                let next = forward ? source.pageViewController(page, viewControllerAfter: cursor)
                    : source.pageViewController(page, viewControllerBefore: cursor)
                guard let next else { return (nil, backs, true) }
                guard seen.insert(ObjectIdentifier(next)).inserted else { return (nil, backs, false) }
                if let face = front(next) { return (face, backs, true) }
                backs.append(next)
                cursor = next
            }
            return (nil, backs, false)
        }
        func key(_ face: ReaderPageHost?) -> String {
            guard let face else { return "none" }
            return "\(face.contentID):\(face.pageIndex)"
        }
        let before = neighbor(false), after = neighbor(true)
        let mounted = page.viewControllers ?? []
        let backs = mounted.dropFirst().filter { front($0) == nil } + before.backs + after.backs
        let fronts = (page.children + mounted).compactMap { front($0) }
            + [before.face, after.face].compactMap { $0 }
        let continuation = ReaderTextLayout.attributedText(text: "续段", count: 0, fontSize: font.pointSize,
            lineSpacing: style.lineSpacing, color: .black, continuation: true)
        let continuationStyle = continuation.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let indent = style.firstLineHeadIndent - style.headIndent
        let continuationIndent = (continuationStyle?.firstLineHeadIndent ?? -1) - (continuationStyle?.headIndent ?? 0)
        // 宽度感知字格可能改变两字缩进，且不再使用逐行 justified；不硬编码 38 或字距。
        let alignment = style.alignment == continuationStyle?.alignment
            && (style.alignment == .left || style.alignment == .natural || style.alignment == .justified)
        let baseline = indent.isFinite && indent > 0 && indent < font.pointSize * 4
            && style.lineSpacing.isFinite && style.lineSpacing >= 0
            && style.minimumLineHeight.isFinite && style.minimumLineHeight > 0
            && style.maximumLineHeight.isFinite && style.maximumLineHeight >= style.minimumLineHeight
        func themed(_ view: UIView) -> Bool { matches(view.backgroundColor, background, traits: view.traitCollection) }
        // 读取真实纸背中的排版正文，不接受只有颜色或只有来源 ID 的占位背面。
        // B(n) 的正文应属于 dataSource 给出的 F(n-1)，跨章与同 ID 刷新也如此。
        func hasPaperText(_ controller: UIViewController) -> Bool {
            guard let back = controller as? ReaderPageBack,
                  let paper = source.pageViewController(page, viewControllerBefore: back) as? ReaderPageHost,
                  let chapter = Int(paper.contentID), let rendered = paragraph(back.view),
                  let body = rendered.attributedText, body.length > 0,
                  rendered.bounds.width > 0, rendered.bounds.height > 0,
                  !rendered.isHidden, rendered.alpha > 0,
                  let ink = body.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor,
                  let expectedInk = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor else { return false }
            return body.string.hasPrefix("第\(chapter + 1)章，第\(paper.pageIndex + 1)页。正文版本\(revision)。")
                && matches(ink, expectedInk, traits: back.view.traitCollection)
        }
        let paperDiagnostics = backs.map { back -> String in
            guard let rendered = paragraph(back.view) else { return "no-paragraph-\(back.view.bounds.size)" }
            return "\(rendered.bounds.size):\(rendered.attributedText.string.prefix(25))"
        }.joined(separator: "|")
        let fields = [
            "paperDiagnostics=\(paperDiagnostics)",
            "native=\(type(of: page) == UIPageViewController.self)", "transition=\(page.transitionStyle == .pageCurl ? "curl" : "scroll")",
            "double=\(page.isDoubleSided)", "idle=\((page.delegate as? PageTurnCoordinator)?.isIdle == true)",
            "current=\(key(host))", "before=\(key(before.face))", "after=\(key(after.face))",
            "chainValid=\(before.valid && after.valid)", "bodyCurrent=\(attributed.string.hasPrefix(bodyPrefix))",
            "alignment=\(alignment ? "production" : "other")", "baseline=\(baseline)",
            "continuation=\(abs(continuationIndent) < 0.5)",
            "containerTheme=\(themed(page.view))", "frontTheme=\(themed(host.view))",
            "backCount=\(backs.count)", "backsTheme=\(backs.allSatisfy { themed($0.view) })",
            "backsOpaque=\(backs.allSatisfy { $0.view.isOpaque && $0.view.alpha == 1 })",
            "backsHidden=\(backs.allSatisfy { $0.view.accessibilityElementsHidden })",
            "backsPaperText=\(backs.filter { $0.view.window != nil }.allSatisfy { hasPaperText($0) })",
            "backsMirrored=\(backs.allSatisfy { $0.children.first?.view.transform == CGAffineTransform(scaleX: -1, y: 1) })",
            "backsInert=\(backs.allSatisfy { !$0.view.isUserInteractionEnabled })",
            "currentOnly=\(!host.view.accessibilityElementsHidden && fronts.allSatisfy { $0 === host || $0.view.accessibilityElementsHidden })",
            "statusHidden=\(page.view.window?.windowScene?.statusBarManager?.isStatusBarHidden == true)"
        ]
        return fields.joined(separator: ";")
    }

    static func paperCandidates(_ page: UIPageViewController) -> [(ReaderPageBack, ReaderPageHost)] {
        guard let source = page.dataSource, let front = page.viewControllers?.first else { return [] }
        return [source.pageViewController(page, viewControllerBefore: front),
                source.pageViewController(page, viewControllerAfter: front)].compactMap { candidate in
            guard let back = candidate as? ReaderPageBack,
                  let paper = source.pageViewController(page, viewControllerBefore: back) as? ReaderPageHost else { return nil }
            return (back, paper)
        }
    }

    static func visiblePaper(_ candidates: [(ReaderPageBack, ReaderPageHost)], background: UIColor, revision: Int) -> String? {
        // UIKit 把纸背绘成卷页纹理后可移出 window/children；保留 dataSource 的真实对象，
        // 检查生成后的字形，而不要求卷页快照阶段它仍是活跃窗口中的子视图。
        for (back, paper) in candidates {
            guard let rendered = paragraph(back.view),
                  let body = rendered.attributedText, body.length > 0,
                  rendered.bounds.width > 0, rendered.bounds.height > 0,
                  let chapter = Int(paper.contentID) else { continue }
            let prefix = "第\(chapter + 1)章，第\(paper.pageIndex + 1)页。正文版本\(revision)。"
            let valid = body.string.hasPrefix(prefix) && matches(back.view.backgroundColor, background,
                traits: back.view.traitCollection) && back.view.isOpaque
                && back.children.first?.view.transform == CGAffineTransform(scaleX: -1, y: 1)
            return "duringBackText=\(valid);duringBackPage=\(paper.contentID):\(paper.pageIndex)"
        }
        return nil
    }

    private static func matches(_ actual: UIColor?, _ expected: UIColor, traits: UITraitCollection) -> Bool {
        guard let actual else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
        guard actual.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a),
              expected.resolvedColor(with: traits).getRed(&er, green: &eg, blue: &eb, alpha: &ea) else { return false }
        return zip([r, g, b, a], [er, eg, eb, ea]).allSatisfy { abs($0.0 - $0.1) < 0.01 } && a > 0.99
    }
}

/// 给系统现有识别器加一个只读 target；只取一次已进入 native interactive 的进度。
/// 不装自制手势、不换 delegate、不查询邻页/布局、不按帧截图，也不向 SwiftUI 发布中途状态。
private final class NativeDragObservation: NSObject {
    private weak var page: UIPageViewController?
    private var recognizers: [UIGestureRecognizer] = []
    private var readProgress: (() -> String)?
    private var background = UIColor.white
    private var papers: [(ReaderPageBack, ReaderPageHost)] = []
    private var revision = 0
    private(set) var snapshot = "observed=false"

    func arm(background: UIColor, revision: Int, readProgress: @escaping () -> String) {
        disarm()
        self.background = background
        self.revision = revision
        snapshot = "observed=false"
        guard let page = NativeReaderInspection.pageController() else { return }
        self.page = page
        papers = NativeReaderInspection.paperCandidates(page)
        self.readProgress = readProgress
        func scrollPans(_ view: UIView) -> [UIGestureRecognizer] {
            var result: [UIGestureRecognizer] = []
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled { result.append(scroll.panGestureRecognizer) }
            return result + view.subviews.flatMap { scrollPans($0) }
        }
        var seen: Set<ObjectIdentifier> = []
        recognizers = (page.gestureRecognizers + scrollPans(page.view)).filter { seen.insert(ObjectIdentifier($0)).inserted }
        recognizers.forEach { $0.addTarget(self, action: #selector(changed(_:))) }
    }

    @objc private func changed(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .changed, let page,
              let coordinator = page.delegate as? PageTurnCoordinator, coordinator.isInteractive,
              let readProgress else { return }
        if !snapshot.hasPrefix("observed=true") {
            snapshot = "observed=true;duringIdle=false;duringCurl=\(page.transitionStyle == .pageCurl);" + readProgress()
        }
        if page.transitionStyle == .pageCurl {
            guard let paper = NativeReaderInspection.visiblePaper(papers, background: background, revision: revision) else { return }
            snapshot += ";" + paper
        }
        disarm()
    }

    private func disarm() {
        recognizers.forEach { $0.removeTarget(self, action: #selector(changed(_:))) }
        recognizers.removeAll()
        readProgress = nil
        page = nil
    }
}
