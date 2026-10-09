import SwiftUI

/// 使用生产手势容器，多章数据离线生成；切章模拟慢请求，检查相同手势不连续跨章。
struct ChapterHarnessView: View {
    let mode: String
    @State private var chapter = 0
    @State private var page = 0
    @State private var loading = false
    @State private var edgeCount = 0
    @State private var bars = 0

    private var pages: [AnyView] {
        (0..<2).map { n in
            AnyView(ZStack {
                Color.white
                VStack {
                    Text("第\(chapter + 1)章，第\(n + 1)页").font(.title2)
                    Text("继续向左翻阅，章末自动下一章。")
                    Spacer()
                }.padding(.top, 140)
            }.ignoresSafeArea())
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
                                            onEdge: advance, onTapCenter: { bars += 1 }).id(chapter)
                } else {
                    PageTurnView(pages: pages, current: $page, style: mode == "curl" ? .curl : .slide,
                                 background: .white, onEdge: advance, onTapCenter: { bars += 1 }).id(chapter)
                }
            }
            .overlay {
                if loading { Color.black.opacity(0.02).contentShape(Rectangle()).overlay(ProgressView()) }
            }
            Text("chapter=\(chapter);page=\(page);edges=\(edgeCount);loading=\(loading);bars=\(bars)")
                .font(.system(size: 11)).frame(height: 44)
                .accessibilityIdentifier("chapter-state")
        }
    }

    private func advance(_ direction: Int) {
        guard !loading else { return }
        let target = chapter + direction
        guard (0..<3).contains(target) else { return }
        loading = true
        edgeCount += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            chapter = target
            page = direction > 0 ? 0 : 1
            loading = false
        }
    }
}
