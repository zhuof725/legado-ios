import SwiftUI

private enum TypographyFixtures {
    static let dialogue = "“春江花月夜，”他说，‘远处的山川——仍在风雨里……’玛丽·苏回答：“明天继续阅读。”"
    static let paragraphs = [String(repeating: dialogue, count: 6), "“好。”", String(repeating: dialogue, count: 4)]
}

private struct TypographyScrollParagraphs: View {
    let size: CGFloat
    let spacing: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(TypographyFixtures.paragraphs.indices, id: \.self) { index in
                InlineCommentParagraph(text: TypographyFixtures.paragraphs[index], count: 82,
                    fontSize: size, lineSpacing: spacing, color: .black, onTap: {})
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 20)
    }
}

struct TypographyHarnessView: View {
    @StateObject private var settings = ReadSettings()
    @State private var showSettings = false
    @State private var metrics = "pending"
    private let title = "这是一个很长的章节标题，用来确认标题不会被截断或从阅读页面消失"

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat(settings.paragraphSpacing)) {
                    ChapterTitleView(title: title, fontSize: CGFloat(settings.fontSize), color: .black)
                        .accessibilityIdentifier("typography-title")
                    InlineCommentParagraph(text: String(repeating: "这是版式设置的长正文，中文标点也应占用同样的字格。", count: 30),
                        count: 82, fontSize: CGFloat(settings.fontSize),
                        lineSpacing: CGFloat(settings.lineSpacing), color: .black, onTap: {})
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("typography-body")
                }
                .padding(.leading, CGFloat(settings.leftMargin))
                .padding(.trailing, CGFloat(settings.rightMargin))
                .padding(.top, CGFloat(settings.topMargin))
                .padding(.bottom, CGFloat(settings.bottomMargin))
            }
            VStack {
                HStack {
                    Spacer()
                    Button("设置") { showSettings = true }
                        .accessibilityIdentifier("open-settings")
                }
                .padding()
                Spacer()
            }
            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Text("阅读设置").font(.headline)
                        Spacer()
                        Button("完成") { showSettings = false }
                            .accessibilityIdentifier("close-settings")
                    }
                    .padding()
                    Form { ReaderTypographyControls(settings: settings) }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(12)
                .shadow(radius: 12)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                Button("检查实际字格与行高") { metrics = TypographyInspection.snapshot() }
                    .accessibilityIdentifier("inspect-typography")
                Text(metrics).font(.system(size: 7)).lineLimit(1)
                    .accessibilityIdentifier("typography-metrics")
            }.frame(maxWidth: .infinity).background(Color.white)
        }
    }
}

/// 在测试 App 内测量生产 UITextView；XCUITest 断言数值，不把 paragraphStyle 当作排版结果。
private enum TypographyInspection {
    private struct Line {
        let glyphs: NSRange
        let rect: CGRect
        let used: CGRect
        let baseline: CGFloat
    }

    private static func lines(_ view: CommentTextView) -> [Line] {
        let manager = view.layoutManager
        manager.ensureLayout(for: view.textContainer)
        var result: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: view.textContainer)) {
            rect, used, _, glyphs, _ in
            guard glyphs.length > 0 else { return }
            let character = manager.characterIndexForGlyph(at: glyphs.location)
            let attachment = view.textStorage.attribute(.attachment, at: character,
                                                       effectiveRange: nil) as? NSTextAttachment
            // 附件独占一行时，glyph location 包含 attachment.bounds 的基线位移。
            // 还原这份位移后才能与普通文字的基线比较，不能把气泡尾巴当成行距误差。
            let baseline = rect.minY + manager.location(forGlyphAt: glyphs.location).y
                + (attachment?.bounds.origin.y ?? 0)
            result.append(Line(glyphs: glyphs, rect: rect, used: used, baseline: baseline))
        }
        return result
    }

    private static func layout(_ view: CommentTextView, text: String, count: Int = 0,
                               width: CGFloat, size: CGFloat, spacing: CGFloat,
                               continuation: Bool = false) -> CGFloat {
        view.render(text: text, count: count, fontSize: size, lineSpacing: spacing,
                    color: .black, continuation: continuation)
        let height = ReaderTextLayout.height(of: view, width: width)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return height
    }

    private static func scrollHostReport() -> [String: Any] {
        let controller = ReaderContinuousScrollController()
        controller.update(ReaderContinuousScrollView(chapters: [ReaderScrollChapter(id: 0,
            revision: "dialogue", content: AnyView(TypographyScrollParagraphs(size: 19, spacing: 8)))],
            request: nil, layoutID: "dialogue", background: .white,
            onPosition: { _, _ in }, onApproachEdge: { _ in }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 391, height: 700))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        var widthError: CGFloat = 0, gridError: CGFloat = 0, heightError: CGFloat = 0
        var glyphs = 0, paragraphs = 0
        var sourceOK = true, bubbleOK = true
        let measurer = ReaderTextLayout.Measurer()
        func descendants(_ root: UIView) -> [CommentTextView] {
            (root as? CommentTextView).map { [$0] } ?? root.subviews.flatMap { descendants($0) }
        }
        // 宽度变化和长短段都经过生产 UIScrollView + UIHostingController，不能只检查离屏测量器。
        for width in [CGFloat(391), 373.5] {
            window.frame.size.width = width
            controller.view.frame = window.bounds
            for _ in 0..<3 {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                controller.children.forEach { $0.view.layoutIfNeeded() }
            }
            let views = descendants(controller.view)
            let expectedWidth = width - 40
            let grid = ReaderTextLayout.metrics(fontSize: 19, width: expectedWidth)
            let origins = views.map { $0.convert(CGPoint.zero, to: controller.view).x }
            if let first = origins.first {
                for x in origins { widthError = max(widthError, abs(x - first)) }
            }
            for view in views {
                paragraphs += 1
                widthError = max(widthError, abs(view.bounds.width - expectedWidth),
                                 abs(view.renderedWidth - expectedWidth), abs(view.textContainer.size.width - expectedWidth))
                guard let text = TypographyFixtures.paragraphs.first(where: { view.textStorage.string == $0 + " \u{FFFC}" }) else {
                    sourceOK = false
                    continue
                }
                heightError = max(heightError, abs(view.bounds.height - measurer.height(text: text, count: 82,
                    width: expectedWidth, fontSize: 19, lineSpacing: 8)))
                let manager = view.layoutManager
                for row in lines(view) {
                    for glyph in row.glyphs.location..<NSMaxRange(row.glyphs) {
                        if manager.characterIndexForGlyph(at: glyph) >= (text as NSString).length { continue }
                        let x = row.rect.minX + manager.location(forGlyphAt: glyph).x
                        gridError = max(gridError, abs(x - (x / grid.cellWidth).rounded() * grid.cellWidth))
                        glyphs += 1
                    }
                }
                if let bubble = view.bubbleRect {
                    bubbleOK = bubbleOK && view.isBubble(at: CGPoint(x: bubble.midX, y: bubble.midY))
                        && !view.isBubble(at: CGPoint(x: bubble.maxX + 2, y: bubble.midY))
                } else { bubbleOK = false }
            }
        }
        return ["scrollWidthError": Double(widthError), "scrollGridError": Double(gridError),
                "scrollHeightError": Double(heightError), "scrollParagraphs": paragraphs,
                "scrollGlyphs": glyphs, "scrollSourceOK": sourceOK, "scrollBubbleOK": bubbleOK]
    }

    static func snapshot() -> String {
        precondition(Thread.isMainThread)
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        let measurer = ReaderTextLayout.Measurer()
        var gridError: CGFloat = 0, stepError: CGFloat = 0, indentError: CGFloat = 0
        var baselineError: CGFloat = 0, heightError: CGFloat = 0, clipping: CGFloat = 0
        var edgeError: CGFloat = 0, tailError: CGFloat = 0, widthError: CGFloat = 0
        var gridGlyphs = 0, baselinePairs = 0, bubbleChecks = 0, preservationChecks = 0
        var bubbleOK = true, nativeRuns = true
        var worstBaseline: [String: Any] = [:]
        let han = String(repeating: "春江花月夜山川风雨天", count: 12)
        let punctuation = String(repeating: "春江，花月。山川；风雨！天地？「阅读」《原文》" + TypographyFixtures.dialogue, count: 8)

        for size in [CGFloat(12), 19, 36] {
            for width in [CGFloat(241), 333.5, 351] {
                let grid = ReaderTextLayout.metrics(fontSize: size, width: width)
                for continued in [false, true] {
                    for text in [han, punctuation] {
                        _ = layout(view, text: text, width: width, size: size, spacing: 8,
                                   continuation: continued)
                        let rows = lines(view)
                        if let first = rows.first {
                            let x = first.rect.minX + view.layoutManager.location(forGlyphAt: first.glyphs.location).x
                            indentError = max(indentError, abs(x - (continued ? 0 : 2 * grid.cellWidth)))
                        }
                        for (rowIndex, row) in rows.enumerated() {
                            var previous: CGFloat?
                            for glyph in row.glyphs.location..<NSMaxRange(row.glyphs) {
                                let x = row.rect.minX + view.layoutManager.location(forGlyphAt: glyph).x
                                gridError = max(gridError, abs(x - (x / grid.cellWidth).rounded() * grid.cellWidth))
                                if let previous { stepError = max(stepError, abs(x - previous - grid.cellWidth)) }
                                previous = x
                                gridGlyphs += 1
                            }
                            if text == han, rowIndex < rows.count - 1, let last = previous {
                                // 非尾行右侧最多留下末字之后的一份字距；不容许整字落空。
                                let right = last + grid.cellWidth - grid.tracking
                                edgeError = max(edgeError, abs(width - right - grid.tracking))
                            }
                        }
                        if view.textStorage.string == text { preservationChecks += 1 }
                    }
                }
                _ = layout(view, text: "尾行", width: width, size: size, spacing: 8)
                if let row = lines(view).first, row.glyphs.length == 2 {
                    let manager = view.layoutManager
                    let span = manager.location(forGlyphAt: row.glyphs.location + 1).x
                        - manager.location(forGlyphAt: row.glyphs.location).x
                    tailError = max(tailError, abs(span - grid.cellWidth))
                } else { tailError = 999 }

                for spacing in [CGFloat(0), 8, 30] {
                    // 有纯中文、西文、重音组合字符、emoji 及气泡的实际换行；不插测试专用硬换行。
                    let mixed = String(repeating: "天地玄黄宇宙洪荒", count: 4)
                        + String(repeating: " AVATAR office affine café e\u{301} 12345 ", count: 3)
                        + "👨‍👩‍👧‍👦🙂🚀" + String(repeating: "继续阅读中文正文", count: 4)
                    let height = layout(view, text: mixed, count: 82, width: width, size: size, spacing: spacing)
                    let rows = lines(view)
                    for (left, right) in zip(rows, rows.dropFirst()) {
                        let error = abs(right.baseline - left.baseline - grid.lineHeight - spacing)
                        if error > baselineError {
                            baselineError = error
                            let manager = view.layoutManager
                            let leftChar = manager.characterIndexForGlyph(at: left.glyphs.location)
                            let rightChar = manager.characterIndexForGlyph(at: right.glyphs.location)
                            let string = view.textStorage.string as NSString
                            worstBaseline = ["size": Double(size), "width": Double(width), "spacing": Double(spacing),
                                "height": Double(grid.lineHeight), "baseline": Double(grid.baseline),
                                "leftY": Double(left.rect.minY), "rightY": Double(right.rect.minY),
                                "leftHeight": Double(left.rect.height), "rightHeight": Double(right.rect.height),
                                "leftBaseline": Double(left.baseline), "rightBaseline": Double(right.baseline),
                                "leftText": string.substring(with: NSRange(location: leftChar, length: min(8, string.length - leftChar))),
                                "rightText": string.substring(with: NSRange(location: rightChar, length: min(8, string.length - rightChar)))]
                        }
                        baselinePairs += 1
                    }
                    for row in rows {
                        let bounds = view.layoutManager.boundingRect(forGlyphRange: row.glyphs, in: view.textContainer)
                        clipping = max(clipping, max(-bounds.minY, bounds.maxY - height))
                    }
                    heightError = max(heightError, abs(height - measurer.height(text: mixed, count: 82,
                        width: width, fontSize: size, lineSpacing: spacing)))
                    widthError = max(widthError, max(abs(view.renderedWidth - width),
                                                    abs(view.textContainer.size.width - width)))
                    if let bubble = view.bubbleRect {
                        bubbleChecks += 1
                        bubbleOK = bubbleOK && bubble.maxY <= height + 0.5 && bubble.maxX <= width + 0.5
                            && view.isBubble(at: CGPoint(x: bubble.midX, y: bubble.midY))
                            && !view.isBubble(at: CGPoint(x: bubble.maxX + 2, y: bubble.midY))
                        // 模拟 SwiftUI 测过另一提议宽度但未提交 frame，命中仍须用屏幕上的字形。
                        _ = view.sizeThatFits(CGSize(width: width + 47, height: .greatestFiniteMagnitude))
                        if let restored = view.bubbleRect {
                            widthError = max(widthError, max(abs(restored.minX - bubble.minX),
                                                           abs(restored.minY - bubble.minY)))
                            widthError = max(widthError, abs(view.renderedWidth - width))
                        } else { bubbleOK = false }
                    } else { bubbleOK = false }
                    let original = (view.textStorage.string as NSString).substring(to: (mixed as NSString).length)
                    if original == mixed, view.textStorage.length == (mixed as NSString).length + 2 {
                        preservationChecks += 1
                    }
                    let latin = (mixed as NSString).range(of: "AVATAR office")
                    let emoji = (mixed as NSString).range(of: "👨‍👩‍👧‍👦")
                    for range in [latin, emoji] {
                        view.textStorage.enumerateAttribute(.kern, in: range) { value, _, _ in
                            if value != nil { nativeRuns = false }
                        }
                    }
                }
            }
        }

        // 西文/emoji 的实际字形数量和横向位置与无字格的系统字体布局比较，而非只查 kern 属性。
        let latin = "“AVATAR” ‘office’ don’t — ffi… café·e\u{301} 👨‍👩‍👧‍👦"
        _ = layout(view, text: latin, width: 700, size: 19, spacing: 8, continuation: true)
        let reference = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(reference)
        reference.attributedText = NSAttributedString(string: latin, attributes: [.font: UIFont.systemFont(ofSize: 19)])
        reference.frame = CGRect(x: 0, y: 0, width: 700, height: 100)
        reference.textContainer.size = CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        reference.layoutManager.ensureLayout(for: reference.textContainer)
        let actualManager = view.layoutManager, referenceManager = reference.layoutManager
        var shapingError: CGFloat = 0
        if actualManager.numberOfGlyphs == referenceManager.numberOfGlyphs {
            for index in 0..<actualManager.numberOfGlyphs {
                shapingError = max(shapingError, abs(actualManager.location(forGlyphAt: index).x
                    - referenceManager.location(forGlyphAt: index).x))
            }
        } else { shapingError = 999 }

        var config = ReaderPaginator.Configuration(pageSize: CGSize(width: 391, height: 380),
                                                   fontSize: 19, lineSpacing: 8)
        config.chapterTitle = "完整章节标题，不占正文的固定行距"
        let source = String(repeating: TypographyFixtures.dialogue + "原文标点，分页偏移。AVATAR👨‍👩‍👧‍👦e\u{301}", count: 12)
        let pages = ReaderPaginator.paginate([
            .paragraph(text: source, commentCount: 82, commentURL: "https://example.invalid/comments"),
            .paragraph(text: "短尾段", commentCount: 0, commentURL: nil)
        ], configuration: config)
        var offset = 0, reconstructed = "", offsetsOK = true, paragraphHeightError: CGFloat = 0
        var pageOverflow: CGFloat = 0, continuationCount = 0, commentCount = 0
        for (pageIndex, page) in pages.enumerated() {
            offsetsOK = offsetsOK && page.startOffset == offset && page.blockHeights.count == page.blocks.count
            var used: CGFloat = 0
            for (index, block) in page.blocks.enumerated() {
                guard case let .paragraph(text, count, _) = block else { continue }
                let continued = page.continuationIndices.contains(index)
                if continued { continuationCount += 1 }
                if count > 0 { commentCount += 1 }
                let measured = measurer.height(text: text, count: count, width: config.textWidth,
                    fontSize: config.fontSize, lineSpacing: config.lineSpacing, continuation: continued)
                let height = index < page.blockHeights.count ? CGFloat(page.blockHeights[index]) : -1
                paragraphHeightError = max(paragraphHeightError, abs(measured - height))
                used += height + (index > 0 ? config.blockSpacing : 0)
                offset += text.count
                reconstructed += text
            }
            let capacity = pageIndex == 0 ? config.firstPageBodyHeight : config.bodyHeight
            pageOverflow = max(pageOverflow, used - capacity)
        }
        var report: [String: Any] = [
            "gridError": Double(gridError), "stepError": Double(stepError), "indentError": Double(indentError),
            "baselineError": Double(baselineError), "heightError": Double(heightError), "clipping": Double(clipping),
            "edgeError": Double(edgeError), "tailError": Double(tailError), "widthError": Double(widthError),
            "gridGlyphs": gridGlyphs, "baselinePairs": baselinePairs, "bubbleChecks": bubbleChecks,
            "preservationChecks": preservationChecks, "bubbleOK": bubbleOK, "nativeRuns": nativeRuns,
            "shapingError": Double(shapingError), "paragraphHeightError": Double(paragraphHeightError),
            "pageOverflow": Double(pageOverflow), "offsetsOK": offsetsOK,
            "sourceOK": reconstructed == source + "短尾段", "continuations": continuationCount,
            "commentCount": commentCount, "pages": pages.count, "worstBaseline": worstBaseline
        ]
        report.merge(scrollHostReport()) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "invalid" }
        return json
    }
}
