import SwiftUI
import UIKit

/// 翻页动画类型（设置里选择）。
enum PageTurnStyle: Int, CaseIterable {
    case slide = 0   // UIPageViewController.TransitionStyle.scroll
    case curl = 1    // UIPageViewController.TransitionStyle.pageCurl

    var title: String {
        switch self {
        case .slide: return "滑动"
        case .curl: return "卷页"
        }
    }
}

/// 一页内容。放进 UIHostingController，由 UIPageViewController 负责翻页。
struct PageContentView: View {
    let page: BookPage
    let fontSize: Double
    let lineSpacing: Double
    let fg: Color
    let bg: Color
    let title: String
    let pageNumber: Int
    let pageCount: Int
    let onTapComment: (String?) -> Void
    var safeInsets = EdgeInsets()
    var paragraphSpacing: Double = 8
    var leftMargin: Double = 20
    var rightMargin: Double = 20
    var topMargin: Double = 16
    var bottomMargin: Double = 10
    var volumeTitle: String? = nil
    var showsChapterTitle = false

    var body: some View {
        ZStack(alignment: .top) {
            bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if let volumeTitle {
                    Spacer(minLength: 0)
                    VolumeTitleView(title: volumeTitle, foreground: fg)
                    Spacer(minLength: 8)
                } else {
                VStack(alignment: .leading, spacing: CGFloat(paragraphSpacing)) {
                if showsChapterTitle && pageNumber == 1 && !title.isEmpty {
                    ChapterTitleView(title: title, fontSize: CGFloat(fontSize), color: UIColor(fg))
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, ChapterTitleLayout.bottomSpacing(fontSize: CGFloat(fontSize)))
                }
                ForEach(Array(page.blocks.enumerated()), id: \.offset) { blockIndex, block in
                    switch block {
                    case .paragraph(let t, let count, let url):
                        let continuation = page.continuationIndices.contains(blockIndex)
                        InlineCommentParagraph(text: t, count: count,
                                                fontSize: fontSize,
                                                lineSpacing: lineSpacing + (page.justifiedGap ?? 0),
                                                color: UIColor(fg),
                                                continuation: continuation,
                                                onTap: { onTapComment(url) })
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: page.justifiedGap != nil && blockIndex < page.blockHeights.count
                                ? CGFloat(page.blockHeights[blockIndex]) : nil, alignment: .top)
                            .padding(.top, blockIndex > 0 ? CGFloat(page.justifiedGap ?? 0) : 0)
                    case .hotComment(let label, let t, let click):
                        HStack(spacing: 10) {
                            Text(label).font(.system(size: max(fontSize - 5, 11), weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                            Text(t).font(.system(size: max(fontSize - 3, 12))).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 22).fill(fg.opacity(0.07)))
                        .onTapGesture { onTapComment(click) }
                    case .chapterComments(let t, let count, _, let click):
                        HStack {
                            Text(t).font(.system(size: fontSize - 2, weight: .bold))
                            Spacer()
                            Text(count).font(.system(size: fontSize - 4)).foregroundStyle(fg.opacity(0.7))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 16).fill(fg.opacity(0.07)))
                        .onTapGesture { onTapComment(click) }
                    case .image(let src, let click):
                        ContentImageView(src: src).onTapGesture { onTapComment(click) }
                    case .inlineBubble:
                        EmptyView()
                    }
                }
                }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(fg)
            .padding(.leading, CGFloat(leftMargin))
            .padding(.trailing, CGFloat(rightMargin))
            .padding(.top, safeInsets.top + CGFloat(topMargin))
            .padding(.bottom, safeInsets.bottom + CGFloat(bottomMargin) + 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).lineLimit(1).accessibilityIdentifier("reader-footer-title")
                    Spacer()
                    Text("\(pageNumber)/\(pageCount)").monospacedDigit().accessibilityIdentifier("reader-footer-page")
                }
                .font(.system(size: 11))
                .foregroundStyle(fg.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .bottom)
                .padding(.leading, CGFloat(leftMargin))
                .padding(.trailing, CGFloat(rightMargin))
                .padding(.bottom, safeInsets.bottom + CGFloat(bottomMargin))
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

/// 已按当前版式完成分页的相邻章节；接纳后 contentID 必须保持不变。
struct PageTurnChapter {
    let contentID: String
    let pages: [AnyView]
}

/// 保持调用接口稳定：滑动使用覆盖翻页，卷页继续交给系统容器。
struct PageTurnView: View {
    let pages: [AnyView]
    @Binding var current: Int
    let style: PageTurnStyle
    let background: UIColor
    let onEdge: (Int) -> Void
    let onTapCenter: () -> Void
    var contentID: String = ""
    var chapterDirection: Int = 0
    /// 每次内容替换稳定后调用（包括系统跳过动画），父层据此解除锁。
    var onContentTransitionCompleted: () -> Void = {}
    var previousChapter: PageTurnChapter? = nil
    var nextChapter: PageTurnChapter? = nil
    /// 仅原生翻页提交后调用；父层原子接纳对应快照和页码，不再发起第二次动画。
    var onChapterTransition: (_ direction: Int, _ pageIndex: Int) -> Void = { _, _ in }

    @ViewBuilder var body: some View {
        switch style {
        case .slide: ReaderCoverPageTurnView(model: self)
        case .curl: NativePageTurnView(model: self, transitionStyle: .pageCurl)
        }
    }

    private struct NativePageTurnView: UIViewControllerRepresentable {
        let model: PageTurnView
        let transitionStyle: UIPageViewController.TransitionStyle

        func makeCoordinator() -> PageTurnCoordinator { PageTurnCoordinator(model) }

        func makeUIViewController(context: Context) -> UIPageViewController {
            let vc = UIPageViewController(transitionStyle: transitionStyle, navigationOrientation: .horizontal,
                options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
            vc.view.backgroundColor = model.background
            // 双面仅提供不透明主题纸背；卷曲、阴影、曲线和跟手仍完全由 UIKit 绘制。
            vc.isDoubleSided = transitionStyle == .pageCurl
            vc.view.clipsToBounds = true
            vc.delegate = context.coordinator
            context.coordinator.attach(vc)

            let pan = ChapterTurnPanObserver(target: context.coordinator, action: #selector(PageTurnCoordinator.panned(_:)))
            pan.delegate = context.coordinator
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            vc.view.addGestureRecognizer(pan)
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(PageTurnCoordinator.tapped(_:)))
            tap.delegate = context.coordinator
            tap.cancelsTouchesInView = false
            tap.require(toFail: pan)
            vc.view.addGestureRecognizer(tap)
            context.coordinator.update(model)
            return vc
        }

        func updateUIViewController(_ vc: UIPageViewController, context: Context) {
            context.coordinator.update(model)
        }
    }
}
