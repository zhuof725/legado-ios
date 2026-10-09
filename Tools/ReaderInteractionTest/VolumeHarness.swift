import SwiftUI

struct VolumeHarnessView: View {
    let mode: String
    let chapters = [
        BookChapter(url: "one", title: "上一卷末章", index: 0),
        BookChapter(url: "", title: "第二卷 风起", index: 1, isVolume: true),
        BookChapter(url: "two", title: "新卷第一章", index: 2)
    ]
    @State private var index = 0
    @State private var page = 0
    @State private var chapterDirection = 0

    private var pages: [AnyView] {
        let chapter = chapters[index]
        let block = ContentBlock.paragraph(text: "测试正文", commentCount: 0, commentURL: nil)
        return [AnyView(PageContentView(page: BookPage(blocks: [block], startOffset: 0),
            fontSize: 19, lineSpacing: 8, fg: .black, bg: .white, title: chapter.title,
            pageNumber: 1, pageCount: 1, onTapComment: { _ in },
            volumeTitle: chapter.isVolume ? chapter.title : nil))]
    }
    var body: some View {
        VStack {
            if mode == "scroll" {
                ScrollView {
                    VStack {
                        if chapters[index].isVolume {
                            VolumeTitleView(title: chapters[index].title, foreground: .black)
                                .frame(height: 260)
                        } else {
                            Text(chapters[index].title).frame(height: 250)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background {
                        ReaderScrollBoundaryObserver(chapterID: String(index), isEnabled: index < 2,
                                                     onNext: { advance(1) })
                    }
                }.id(index)
            } else {
                PageTurnView(pages: pages, current: $page,
                    style: mode == "curl" ? .curl : .slide,
                    background: .white, onEdge: advance, onTapCenter: {},
                    contentID: "\(index)", chapterDirection: chapterDirection,
                    onContentTransitionCompleted: { chapterDirection = 0 })
            }
            Text("entry=\(index);volume=\(chapters[index].isVolume)")
                .accessibilityIdentifier("volume-state")
        }
    }
    private func advance(_ direction: Int) {
        guard let target = ChapterNavigation.displayIndex(from: index + direction,
            direction: direction, chapters: chapters) else { return }
        index = target
        page = 0
        chapterDirection = direction
    }
}
