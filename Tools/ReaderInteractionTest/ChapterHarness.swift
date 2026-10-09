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
    @State private var metrics = "none"
    private var night: Bool { mode == "curl-night" }
    private var background: UIColor { night ? UIColor(white: 0.11, alpha: 1) : .white }
    private var foreground: Color { night ? .gray : .black }

    private var pages: [AnyView] {
        (0..<2).map { n in
            AnyView(PageContentView(
                page: BookPage(blocks: [.paragraph(text: "第\(chapter + 1)章，第\(n + 1)页。" + String(repeating: "继续向左翻阅，章末自动下一章。", count: n == 0 ? 6 : 1), commentCount: 0, commentURL: nil)], startOffset: n * 100),
                fontSize: 19, lineSpacing: 8, fg: foreground, bg: Color(background),
                title: "第\(chapter + 1)章，第\(n + 1)页", pageNumber: n + 1, pageCount: 2,
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
                Text("chapter=\(chapter);page=\(page);edges=\(edgeCount);loading=\(loading);bars=\(bars);locked=\(edgeLocked)")
                    .font(.system(size: 10)).accessibilityIdentifier("chapter-state")
                HStack {
                    Button("检查动画") { metrics = AnimationProbe.snapshotMetrics() }.accessibilityIdentifier("inspect-animation")
                    Button("记录动画") { AnimationProbe.arm() }.accessibilityIdentifier("arm-animation")
                }.font(.caption)
                Text(metrics).font(.system(size: 6)).accessibilityIdentifier("animation-metrics")
            }.frame(height: 60).background(Color.white)
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
        Task { @MainActor in
            if !night { try? await Task.sleep(nanoseconds: 700_000_000) }
            chapter = target
            page = direction > 0 ? 0 : 1
            loading = false
        }
    }
}
