import UIKit

/// UIKit 分页器：分页和 InlineCommentParagraph 使用相同的 TextKit 属性与附件。
/// Engine/Paginator.swift 继续提供 Foundation 估算分页，供源书回归和无 UIKit 场景使用。
enum ReaderPaginator {
    struct Configuration: Equatable {
        var pageSize: CGSize
        var safeInsets: UIEdgeInsets = .zero
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var horizontalInset: CGFloat = 20
        var topInset: CGFloat = 16
        var bottomInset: CGFloat = 10
        /// PageContentView 底部页码栏的保留高度。
        var footerHeight: CGFloat = 16
        var blockSpacing: CGFloat = 2

        var textWidth: CGFloat {
            max(pageSize.width - horizontalInset * 2, 1)
        }

        var bodyHeight: CGFloat {
            max(pageSize.height - safeInsets.top - safeInsets.bottom
                - topInset - bottomInset - footerHeight, 1)
        }
    }

    /// 返回的 BookPage.blockHeights 与 PageContentView 的块顺序一一对应。
    /// 入口应在主线程调用，因为 TextKit/UIKit 不支持后台布局。
    static func paginate(_ blocks: [ContentBlock], configuration: Configuration) -> [BookPage] {
        precondition(Thread.isMainThread, "ReaderPaginator must run on the main thread")
        guard !blocks.isEmpty else { return [] }
        let measurer = ReaderTextLayout.Measurer()
        let width = configuration.textWidth
        let capacity = configuration.bodyHeight
        var pages: [BookPage] = []
        var pageBlocks: [ContentBlock] = []
        var pageHeights: [Double] = []
        var continuations = Set<Int>()
        var used: CGFloat = 0
        var offset = 0
        var pageStart = 0

        func flush() {
            guard !pageBlocks.isEmpty else { return }
            pages.append(BookPage(blocks: pageBlocks, startOffset: pageStart,
                                  continuationIndices: continuations,
                                  blockHeights: pageHeights))
            pageBlocks.removeAll(keepingCapacity: true)
            pageHeights.removeAll(keepingCapacity: true)
            continuations.removeAll(keepingCapacity: true)
            used = 0
            pageStart = offset
        }

        func append(_ block: ContentBlock, height: CGFloat, continuation: Bool = false) {
            if !pageBlocks.isEmpty { used += configuration.blockSpacing }
            if continuation { continuations.insert(pageBlocks.count) }
            pageBlocks.append(block)
            pageHeights.append(Double(height))
            used += height
        }

        for block in blocks {
            switch block {
            case .paragraph(let text, let commentCount, let commentURL):
                let chars = Array(text)
                if chars.isEmpty { continue }
                var index = 0
                var continuation = false
                while index < chars.count {
                    let remaining = chars.count - index
                    let room = capacity - used - (pageBlocks.isEmpty ? 0 : configuration.blockSpacing)
                    if room <= 0.5, !pageBlocks.isEmpty {
                        flush()
                        continue
                    }

                    // 先尝试整段。气泡只在整段最后一块测量和附加。
                    let wholeFits = remaining > 0 && measuredHeight(
                        measurer: measurer, chars: chars, start: index, count: remaining,
                        isLast: true, commentCount: commentCount, width: width,
                        configuration: configuration, room: room)
                    let take: Int
                    if wholeFits {
                        take = remaining
                    } else {
                        // 二分查找可放入本页的最大字符前缀；候选前缀没有气泡。
                        var low = 1
                        var high = max(remaining - 1, 1)
                        var best = 0
                        while low <= high {
                            let mid = (low + high) / 2
                            let h = measured(measurer: measurer, chars: chars, start: index,
                                             count: mid, commentCount: 0, width: width,
                                             fontSize: configuration.fontSize,
                                             lineSpacing: configuration.lineSpacing,
                                             continuation: continuation)
                            if h + (pageBlocks.isEmpty ? 0 : configuration.blockSpacing) <= capacity - used + 0.01 {
                                best = mid
                                low = mid + 1
                            } else {
                                high = mid - 1
                            }
                        }
                        // 任何正常页面都能容纳一个字符；若当前页剩余空间不够，先换页再重试。
                        if best == 0 && !pageBlocks.isEmpty {
                            flush()
                            continue
                        }
                        take = max(best, 1)
                    }

                    let end = index + take
                    let isLast = end == chars.count
                    let piece = String(chars[index..<end])
                    let h = measured(measurer: measurer, chars: chars, start: index, count: take,
                                     commentCount: isLast ? commentCount : 0, width: width,
                                     fontSize: configuration.fontSize, lineSpacing: configuration.lineSpacing,
                                     continuation: continuation)
                    if used + h + (pageBlocks.isEmpty ? 0 : configuration.blockSpacing) > capacity + 0.01,
                       !pageBlocks.isEmpty {
                        flush()
                        continue
                    }
                    append(.paragraph(text: piece,
                                      commentCount: isLast ? commentCount : 0,
                                      commentURL: isLast ? commentURL : nil),
                           height: h, continuation: continuation)
                    offset += take
                    index = end
                    continuation = true
                    if !isLast { flush() }
                }
            default:
                let h = nonTextHeight(block, configuration: configuration)
                if used + h + (pageBlocks.isEmpty ? 0 : configuration.blockSpacing) > capacity + 0.01,
                   !pageBlocks.isEmpty {
                    flush()
                }
                append(block, height: h)
            }
        }
        flush()
        return pages
    }

    private static func measured(measurer: ReaderTextLayout.Measurer, chars: [Character], start: Int,
                                 count: Int, commentCount: Int, width: CGFloat, fontSize: CGFloat,
                                 lineSpacing: CGFloat, continuation: Bool) -> CGFloat {
        let text = String(chars[start..<(start + count)])
        return measurer.height(text: text, count: commentCount, width: width, fontSize: fontSize,
                               lineSpacing: lineSpacing, continuation: continuation)
    }

    private static func measuredHeight(measurer: ReaderTextLayout.Measurer, chars: [Character], start: Int,
                                       count: Int, isLast: Bool, commentCount: Int, width: CGFloat,
                                       configuration: Configuration, room: CGFloat) -> Bool {
        let h = measured(measurer: measurer, chars: chars, start: start, count: count,
                         commentCount: isLast ? commentCount : 0, width: width,
                         fontSize: configuration.fontSize, lineSpacing: configuration.lineSpacing,
                         continuation: start > 0)
        return h <= room + 0.01
    }

    /// 与 PageContentView 的 SwiftUI 固定 padding/字体相同的非文本块高度。
    static func nonTextHeight(_ block: ContentBlock, configuration: Configuration) -> CGFloat {
        switch block {
        case .image:
            return 120
        case .hotComment:
            return max(configuration.fontSize - 3, 12) + 20
        case .chapterComments:
            return max(configuration.fontSize - 2, 11) + 24
        case .inlineBubble, .paragraph:
            return 0
        }
    }
}
