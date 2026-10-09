import SwiftUI

/// 使用生产手势容器，多章数据离线生成；切章模拟慢请求，检查相同手势不连续跨章。
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
    @State private var themeFlipped = false
    @State private var slowLoads = 0
    @State private var cachedLoads = 0
    private var night: Bool { (mode == "curl-night") != themeFlipped }
    private var background: UIColor { night ? UIColor(white: 0.11, alpha: 1) : .white }
    private var foreground: Color { night ? .gray : .black }
    private var loadMode: String {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--chapter-load=") }
            .map { String($0.dropFirst("--chapter-load=".count)) } ?? (mode == "curl-night" ? "cached" : "slow")
    }
    private var revisionSuffix: String { revision == 0 ? "" : " · 更新\(revision)" }

    private var pages: [AnyView] {
        (0..<2).map { n in
            AnyView(PageContentView(
                page: BookPage(blocks: [.paragraph(text: "第\(chapter + 1)章，第\(n + 1)页。正文版本\(revision)。" + String(repeating: "继续向左翻阅，章末自动下一章。", count: n == 0 ? 6 : 1), commentCount: 0, commentURL: nil)], startOffset: n * 100),
                fontSize: 19, lineSpacing: 8, fg: foreground, bg: Color(background),
                title: "第\(chapter + 1)章，第\(n + 1)页" + revisionSuffix, pageNumber: n + 1, pageCount: 2,
                onTapComment: { _ in }, safeInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
                showsChapterTitle: true).ignoresSafeArea())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                } else if mode == "fade" {
                    InteractivePageTurnView(pages: pages, current: $page, style: .fade,
                                            onEdge: advance, onTapCenter: { bars += 1 },
                                            contentID: "\(chapter)", chapterDirection: chapterDirection,
                                            onContentTransitionCompleted: { chapterDirection = 0; edgeLocked = false })
                } else {
                    PageTurnView(pages: pages, current: $page, style: mode.hasPrefix("curl") ? .curl : .slide,
                                 background: background, onEdge: advance, onTapCenter: { bars += 1 },
                                 contentID: "\(chapter)", chapterDirection: chapterDirection,
                                 onContentTransitionCompleted: { chapterDirection = 0; edgeLocked = false })
                }
            }
            .overlay {
                if loading { Color.black.opacity(0.02).contentShape(Rectangle()).overlay(ProgressView()) }
            }
            VStack(spacing: 2) {
                Text("chapter=\(chapter);page=\(page);edges=\(edgeCount);loading=\(loading);bars=\(bars);locked=\(edgeLocked);contentID=\(chapter);count=2;revision=\(revision);night=\(night);load=\(loadMode);slow=\(slowLoads);cached=\(cachedLoads)")
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.3)
                    .accessibilityIdentifier("chapter-state")
                HStack {
                    // 不改 contentID、页数、current，也不手动调用生产完成回调。
                    Button("刷新标题/正文") { revision += 1 }.accessibilityIdentifier("refresh-content")
                    Button("切换主题") { themeFlipped.toggle() }.accessibilityIdentifier("toggle-theme")
                }.font(.caption).disabled(loading || edgeLocked)
                AnimationProbeControls()
            }.frame(height: 88).background(Color.white)
        }
    }

    private func advance(_ direction: Int) {
        guard !loading, !edgeLocked else { return }
        let target = chapter + direction
        guard (0..<3).contains(target) else { return }
        loading = true
        edgeCount += 1
        chapterDirection = mode == "scroll" || mode == "short" ? 0 : direction
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
