import SwiftUI
import CoreText

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
        if ProcessInfo.processInfo.arguments.contains("--reference-page") {
            ReferenceTypographyPage()
        } else {
            inspectionBody
        }
    }

    private var inspectionBody: some View {
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
                    var hanStep: CGFloat?
                    for glyph in row.glyphs.location..<NSMaxRange(row.glyphs) {
                        if manager.characterIndexForGlyph(at: glyph) >= (text as NSString).length { continue }
                        let x = row.rect.minX + manager.location(forGlyphAt: glyph).x
                        // Curly quotes shift the grid phase locally. Adjacent Han still
                        // advance exactly one cell; optical marks are checked separately.
                        let ci = manager.characterIndexForGlyph(at: glyph)
                        let ns = text as NSString
                        if glyph > row.glyphs.location, ci > 0,
                           (0x4E00...0x9FFF).contains(Int(ns.character(at: ci))),
                           (0x4E00...0x9FFF).contains(Int(ns.character(at: ci - 1))) {
                            let step = x - row.rect.minX - manager.location(forGlyphAt: glyph - 1).x
                            gridError = max(gridError, abs(step - (hanStep ?? step)))
                            hanStep = step
                        }
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

    /// 单独绘制生产 TextKit 的一个字形，读取实际透明位图的墨迹范围。
    /// 不用 advance / paragraphStyle 代替可见字面位置。
    private static func ink(_ view: CommentTextView, character: Int) -> CGRect? {
        let manager = view.layoutManager
        let range = manager.glyphRange(forCharacterRange: NSRange(location: character, length: 1),
                                       actualCharacterRange: nil)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            manager.drawGlyphs(forGlyphRange: range, at: .zero)
        }
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let found: CGRect? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let data = bytes.bindMemory(to: UInt8.self)
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                for x in 0..<w where data[(y * w + x) * 4 + 3] > 32 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX else { return nil }
            return CGRect(x: CGFloat(minX) / 3, y: CGFloat(minY) / 3,
                          width: CGFloat(maxX - minX + 1) / 3, height: CGFloat(maxY - minY + 1) / 3)
        }
        return found
    }

    private static func punctuationReport() -> [String: Any] {
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        var inkOK = true, wrappingOK = true
        var inkChecks = 0, breakChecks = 0
        var bubbleGapError: CGFloat = 0, bubbleBaselineError: CGFloat = 0
        var inkSamples: [String: [Double]] = [:]
        for size in [CGFloat(12), 19, 36] {
            let width: CGFloat = 351
            let grid = ReaderTextLayout.metrics(fontSize: size, width: width)
            // 横排简体句读在左下；开引号/开括号靠右，闭引号/闭括号靠左。
            for mark in ["，", "。", "！", "‘", "’", "“", "”", "【", "】"] {
                _ = layout(view, text: "汉" + mark + "汉", width: width, size: size, spacing: 8, continuation: true)
                guard let bounds = ink(view, character: 1), let han = ink(view, character: 0) else {
                    inkOK = false; continue
                }
                let glyph = view.layoutManager.glyphIndexForCharacter(at: 1)
                let x = view.layoutManager.location(forGlyphAt: glyph).x
                let fraction = (bounds.midX - x) / grid.cellWidth
                inkSamples["\(size):\(mark)"] = [Double(fraction), Double(bounds.midY - han.midY)]
                if mark == "【" { inkOK = inkOK && fraction > 0.5 }
                else { inkOK = inkOK && fraction < 0.5 }
                if ["，", "。"].contains(mark) { inkOK = inkOK && bounds.midY > han.midY }
                inkChecks += 1
            }
            // 不改写标点，不手动插入换行：覆盖不同剩余字格的系统避头尾。
            for prefix in 0..<12 {
                let text = String(repeating: "汉", count: prefix) + "‘我的天赋还不错！’亦或者说，这本【素月莲华刀】很好。"
                _ = layout(view, text: text, width: size * 8.3, size: size, spacing: 8, continuation: true)
                let string = text as NSString
                for row in lines(view) {
                    let chars = view.layoutManager.characterRange(forGlyphRange: row.glyphs, actualGlyphRange: nil)
                    let part = string.substring(with: chars)
                    if let first = part.first, let last = part.last {
                        wrappingOK = wrappingOK && !"，。！’】".contains(first) && !"‘【".contains(last)
                        breakChecks += 1
                    }
                }
            }
            let text = "我的天赋还不错！’"
            _ = layout(view, text: text, width: width, size: size, spacing: 8)
            let plainBaseline = lines(view).last?.baseline ?? -999
            let plainHeight = view.bounds.height
            _ = layout(view, text: text, count: 3, width: width, size: size, spacing: 8)
            let manager = view.layoutManager
            let gap = manager.glyphIndexForCharacter(at: (text as NSString).length)
            let attachment = manager.glyphIndexForCharacter(at: (text as NSString).length + 1)
            bubbleGapError = max(bubbleGapError, abs(manager.location(forGlyphAt: attachment).x
                - manager.location(forGlyphAt: gap).x - grid.cellWidth * 0.25))
            bubbleBaselineError = max(bubbleBaselineError, abs((lines(view).last?.baseline ?? 999) - plainBaseline),
                                      abs(view.bounds.height - plainHeight))
        }
        return ["inkOK": inkOK, "inkChecks": inkChecks, "inkSamples": inkSamples,
                "wrappingOK": wrappingOK, "breakChecks": breakChecks,
                "bubbleGapError": Double(bubbleGapError), "bubbleBaselineError": Double(bubbleBaselineError)]
    }

    /// 检查真实整段 + 内层引号的原生排版；不能用“每行必须填满”掩盖字间拉伸。
    private static func quoteGlyphReport() -> [String: Any] {
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        var correctFont = true, distinctGlyphs = true, sourceOK = true
        var glyphNames: [[String: Any]] = []
        for size in [CGFloat(19), 23, 24, 26] {
            let text = "“陈迹，‘很轻’，可以吗？”"
            _ = layout(view, text: text, width: 351, size: size, spacing: 8)
            let ns = text as NSString
            sourceOK = sourceOK && view.textStorage.string == text
            let font = ReaderTextLayout.metrics(fontSize: size, width: 351).quoteFont
            let actualName = CTFontCopyPostScriptName(font as CTFont) as String
            var ids: [String: Int] = [:]
            for index in 0..<ns.length {
                let code = ns.character(at: index)
                guard [0x2018, 0x2019, 0x201C, 0x201D].contains(code) else { continue }
                let applied = view.textStorage.attribute(.font, at: index, effectiveRange: nil) as? UIFont
                correctFont = correctFont && applied.map { CTFontCopyPostScriptName($0 as CTFont) as String == actualName } == true
                let key = ns.substring(with: NSRange(location: index, length: 1))
                let glyph = view.layoutManager.glyphIndexForCharacter(at: index)
                ids[key] = Int(view.layoutManager.glyph(at: glyph))
                glyphNames.append(["size": Double(size), "quote": key,
                    "unicode": Int(code), "font": actualName, "glyph": ids[key] ?? -1])
            }
            distinctGlyphs = distinctGlyphs && ids["“"] != ids["”"] && ids["‘"] != ids["’"]
                && ids.count == 4 && ids.values.allSatisfy { $0 > 0 }
        }
        return ["quoteCorrectFont": correctFont, "quoteDistinctGlyphs": distinctGlyphs,
                "quoteSourceOK": sourceOK, "quoteGlyphs": glyphNames]
    }

    private static func naturalRowsReport() -> [String: Any] {
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        var samples: [[String: Any]] = []
        var stepError: CGFloat = 0, edgeCells: CGFloat = 0
        var checked = 0, terminalRows = 0, hanPairs = 0
        var breaksOK = true, sourceOK = true
        for size in [CGFloat(19), 23, 24, 26] {
            for width in [CGFloat(333.5), 351, 362, 370] {
                let text = ReferenceTypography.texts[2]
                let ns = text as NSString
                let grid = ReaderTextLayout.metrics(fontSize: size, width: width)
                _ = layout(view, text: text, count: 99, width: width, size: size, spacing: 8)
                sourceOK = sourceOK && view.textStorage.string == text + " \u{FFFC}"
                let manager = view.layoutManager
                let rows = lines(view)
                for row in rows {
                    let cr = manager.characterRange(forGlyphRange: row.glyphs, actualGlyphRange: nil)
                    let part = (view.textStorage.string as NSString).substring(with: cr)
                    // Some widths wrap only the comment attachment after the final
                    // text row; this is not another paragraph terminal text row.
                    guard !part.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\u{FFFC}", with: "").isEmpty else { continue }
                    if let first = part.first, let last = part.last {
                        breaksOK = breaksOK && !"，。！？；：、’”】》」".contains(first)
                            && !"‘“【《「".contains(last)
                    }
                    for g in (row.glyphs.location + 1)..<NSMaxRange(row.glyphs) {
                        let a = manager.characterIndexForGlyph(at: g - 1)
                        let b = manager.characterIndexForGlyph(at: g)
                        if b < ns.length, (0x4E00...0x9FFF).contains(Int(ns.character(at: a))),
                           (0x4E00...0x9FFF).contains(Int(ns.character(at: b))) {
                            let step = manager.location(forGlyphAt: g).x - manager.location(forGlyphAt: g - 1).x
                            stepError = max(stepError, abs(step - grid.cellWidth))
                            hanPairs += 1
                        }
                    }
                    let terminal = NSMaxRange(cr) >= ns.length
                    if terminal { terminalRows += 1 }
                    else {
                        edgeCells = max(edgeCells, max(0, width - row.used.maxX) / grid.cellWidth)
                        checked += 1
                    }
                    samples.append(["size": Double(size), "width": Double(width), "text": part,
                        "right": Double(row.used.maxX), "terminal": terminal])
                }
            }
        }
        return ["naturalStepError": Double(stepError), "naturalEdgeCells": Double(edgeCells),
                "naturalHanPairs": hanPairs, "naturalRows": checked,
                "naturalTerminalRows": terminalRows, "naturalBreaksOK": breaksOK,
                "naturalSourceOK": sourceOK, "naturalSamples": samples]
    }

    private static func referenceReport() -> [String: Any] {
        let view = ReaderTextLayout.makeTextView()
        ReaderTextLayout.configure(view)
        var compact = true, preserved = true
        var openingError: CGFloat = 0, maxGap: CGFloat = 0, minGap: CGFloat = 0
        var bubbleGap: CGFloat = 0
        var checks = 0
        for size in [CGFloat(12), 19, 36] {
            let width: CGFloat = 351
            let grid = ReaderTextLayout.metrics(fontSize: size, width: width)
            for (index, text) in ReferenceTypography.texts.enumerated() {
                _ = layout(view, text: text, count: ReferenceTypography.counts[index], width: width, size: size, spacing: 8)
                preserved = preserved && view.textStorage.string == text + " \u{FFFC}"
                let ns = text as NSString
                if text.hasPrefix("“"), let opening = ink(view, character: 0) {
                    openingError = max(openingError, abs(opening.minX - grid.cellWidth * 2) / grid.cellWidth)
                }
                for ci in 1..<ns.length {
                    let mark = ns.substring(with: NSRange(location: ci, length: 1))
                    let previous = ns.substring(with: NSRange(location: ci - 1, length: 1))
                    guard "‘’“”、".contains(mark) || "‘’“”".contains(previous),
                          let left = ink(view, character: ci - 1), let right = ink(view, character: ci),
                          abs(left.midY - right.midY) < grid.lineHeight,
                          right.minX >= left.minX else { continue }
                    let gap = (right.minX - left.maxX) / grid.cellWidth
                    maxGap = max(maxGap, gap)
                    minGap = min(minGap, gap)
                    compact = compact && gap < 0.9 && gap > -0.2
                    checks += 1
                }
                if text.hasSuffix("”"), let last = ink(view, character: ns.length - 1), let bubble = view.bubbleRect,
                   bubble.minX > last.maxX {
                    let gap = (bubble.minX - last.maxX) / grid.cellWidth
                    bubbleGap = max(bubbleGap, gap)
                    compact = compact && gap < 0.9
                }
            }
        }
        return ["referenceCompact": compact, "referencePreserved": preserved,
                "referenceOpeningError": Double(openingError), "referenceMaxGap": Double(maxGap),
                "referenceMinGap": Double(minGap), "referenceBubbleGap": Double(bubbleGap),
                "referenceChecks": checks]
    }

    private static func bottomReport() -> [String: Any] {
        var baselineError: CGFloat = 0, overflow: CGFloat = 0, topError: CGFloat = 0
        var checked = 0, continued = 0, comments = 0
        var terminalOK = true, specialOK = true
        func descendants(_ root: UIView) -> [CommentTextView] {
            (root as? CommentTextView).map { [$0] } ?? root.subviews.flatMap { descendants($0) }
        }
        for size in [CGFloat(12), 19, 36] {
            var config = ReaderPaginator.Configuration(pageSize: CGSize(width: 391, height: 720),
                safeInsets: UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
                fontSize: size, lineSpacing: 8, paragraphSpacing: 7,
                leftInset: 23, rightInset: 31, topInset: 19, bottomInset: 17)
            config.chapterTitle = "标题保持顶部位置，正文末行统一高度"
            let blocks: [ContentBlock] = (0..<12).map { index in
                .paragraph(text: String(repeating: TypographyFixtures.dialogue, count: index % 3 + 1),
                    commentCount: 82, commentURL: nil)
            } + [.paragraph(text: "章末短尾段", commentCount: 3, commentURL: nil)]
            let pages = ReaderPaginator.paginate(blocks, configuration: config)
            terminalOK = terminalOK && pages.last?.justifiedGap == nil
            for (index, page) in pages.enumerated() {
                if index != pages.count - 1 && page.justifiedGap == nil { terminalOK = false }
                let content = PageContentView(page: page, fontSize: Double(size), lineSpacing: 8,
                    fg: .black, bg: .white, title: config.chapterTitle, pageNumber: index + 1,
                    pageCount: pages.count, onTapComment: { _ in },
                    safeInsets: EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0),
                    paragraphSpacing: 7, leftMargin: 23, rightMargin: 31, topMargin: 19,
                    bottomMargin: 17, showsChapterTitle: true)
                let host = UIHostingController(rootView: content)
                let window = UIWindow(frame: CGRect(origin: .zero, size: config.pageSize))
                window.rootViewController = host
                window.isHidden = false
                host.view.frame = window.bounds
                for _ in 0..<3 { host.view.setNeedsLayout(); host.view.layoutIfNeeded() }
                let views = descendants(host.view).sorted {
                    $0.convert(CGPoint.zero, to: host.view).y < $1.convert(CGPoint.zero, to: host.view).y
                }
                if index == 0 {
                    func labels(_ root: UIView) -> [UILabel] {
                        (root as? UILabel).map { [$0] } ?? root.subviews.flatMap { labels($0) }
                    }
                    if let label = labels(host.view).first(where: { $0.accessibilityIdentifier == "chapter-title" }),
                       let first = views.first {
                        let frame = label.convert(label.bounds, to: host.view)
                        let expectedCenter = config.leftInset + config.textWidth / 2
                        terminalOK = terminalOK && label.textAlignment == .center
                            && abs(frame.midX - expectedCenter) < 0.75
                            && abs(first.convert(.zero, to: host.view).y - frame.maxY
                                - ChapterTitleLayout.bottomSpacing(fontSize: size) - config.paragraphSpacing) < 0.75
                    } else { terminalOK = false }
                }
                let grid = ReaderTextLayout.metrics(fontSize: size, width: config.textWidth)
                let bottom = config.pageSize.height - 34 - config.bottomInset - 24
                let top = 47 + config.topInset + (index == 0 ? config.headerHeight : 0)
                if let first = views.first {
                    topError = max(topError, abs(first.convert(CGPoint.zero, to: host.view).y - top))
                } else { topError = 999 }
                if let last = views.last, let row = lines(last).last {
                    let y = last.convert(CGPoint(x: 0, y: row.baseline), to: host.view).y
                    if page.justifiedGap != nil {
                        baselineError = max(baselineError, abs(y - (bottom - grid.lineHeight + grid.baseline)))
                        checked += 1
                    }
                    overflow = max(overflow, y + grid.lineHeight - grid.baseline - bottom)
                }
                if index == pages.count - 1 {
                    var expectedY = top
                    for (blockIndex, view) in views.enumerated() {
                        let origin = view.convert(CGPoint.zero, to: host.view).y
                        terminalOK = terminalOK && abs(origin - expectedY) <= 0.75
                        let rows = lines(view)
                        for pair in zip(rows, rows.dropFirst()) {
                            terminalOK = terminalOK && abs(pair.1.baseline - pair.0.baseline - grid.lineHeight - 8) <= 0.5
                        }
                        if blockIndex < page.blockHeights.count {
                            expectedY += CGFloat(page.blockHeights[blockIndex]) + config.paragraphSpacing
                        } else { terminalOK = false }
                    }
                }
                for view in views {
                    if let rect = view.bubbleRect {
                        if !view.isBubble(at: CGPoint(x: rect.midX, y: rect.midY)) { terminalOK = false }
                        comments += 1
                    }
                }
                continued += page.continuationIndices.count
                window.isHidden = true
                window.rootViewController = nil
            }
            let short = ReaderPaginator.paginate([.paragraph(text: "短章", commentCount: 1, commentURL: nil)], configuration: config)
            terminalOK = terminalOK && short.count == 1 && short[0].justifiedGap == nil
            let mixed = ReaderPaginator.paginate([.image(src: "", clickURL: nil)] + blocks, configuration: config)
            specialOK = specialOK && mixed.first?.justifiedGap == nil
        }
        return ["bottomBaselineError": Double(baselineError), "bottomOverflow": Double(overflow),
                "bottomTopError": Double(topError), "bottomPages": checked, "bottomContinuations": continued,
                "bottomComments": comments, "bottomTerminalOK": terminalOK, "bottomSpecialOK": specialOK]
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
                            var hanStep: CGFloat?
                            for glyph in row.glyphs.location..<NSMaxRange(row.glyphs) {
                                let x = row.rect.minX + view.layoutManager.location(forGlyphAt: glyph).x
                                if text == han {
                                    gridError = max(gridError, abs(x - (x / grid.cellWidth).rounded() * grid.cellWidth))
                                }
                                if let previous {
                                    let manager = view.layoutManager
                                    let ci = manager.characterIndexForGlyph(at: glyph - 1)
                                    let ns = text as NSString
                                    let mark = ns.substring(with: NSRange(location: ci, length: 1))
                                    var expected = grid.cellWidth
                                    if "‘’“”".contains(mark) {
                                        let sample = NSAttributedString(string: mark, attributes: [.font: grid.quoteFont, .kern: 0, .ligature: 0])
                                        expected = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(sample), nil, nil, nil))
                                    }
                                    let next = manager.characterIndexForGlyph(at: glyph)
                                    let adjacentHan = (0x4E00...0x9FFF).contains(Int(ns.character(at: ci)))
                                        && (0x4E00...0x9FFF).contains(Int(ns.character(at: next)))
                                    if text != han && adjacentHan {
                                        // Mixed rows have one uniform Han step; optical punctuation
                                        // still has its original measured advance, checked below.
                                        let step = x - previous
                                        expected = hanStep ?? step
                                        hanStep = step
                                    }
                                    stepError = max(stepError, abs(x - previous - expected))
                                }
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
                let gap = CGFloat(page.justifiedGap ?? 0)
                let measured = measurer.height(text: text, count: count, width: config.textWidth,
                    fontSize: config.fontSize, lineSpacing: config.lineSpacing + gap, continuation: continued)
                let height = index < page.blockHeights.count ? CGFloat(page.blockHeights[index]) : -1
                let actual = page.justifiedGap == nil ? measured : measurer.rows(text: text, count: count,
                    width: config.textWidth, fontSize: config.fontSize, lineSpacing: config.lineSpacing + gap,
                    continuation: continued).height
                paragraphHeightError = max(paragraphHeightError, abs(actual - height))
                used += height + (index > 0 ? config.blockSpacing + gap : 0)
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
        report.merge(bottomReport()) { _, new in new }
        report.merge(scrollHostReport()) { _, new in new }
        report.merge(quoteGlyphReport()) { _, new in new }
        report.merge(naturalRowsReport()) { _, new in new }
        report.merge(referenceReport()) { _, new in new }
        report.merge(punctuationReport()) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "invalid" }
        return json
    }
}


private enum ReferenceTypography {
    static let texts = [
        "洛城，秋。",
        "空洞的办公室里，惨白的白炽灯下，中年医生推了推鼻梁上的眼镜。",
        "“陈迹你好，我现在需要问你一些问题。你回答后，我会根据我的判断，按照‘无’、‘很轻’、‘中等’、‘严重’、‘非常严重’这五个程度来做出评分，可以吗？”",
        "“可以。”", "“你想结束生命吗？”", "“……结束谁的生命？”", "“你自己的。”", "“那没有。”",
        "中年医生迟疑片刻：“你是否记仇，是否很难原谅那些伤害过你的人？”", "“我不记仇。”",
        "“你是否会常常忘记事情，你是否会感到疲惫？”"
    ]
    static let counts = [99,82,99,46,55,99,31,37,42,99,82]
    static var blocks: [ContentBlock] { texts.enumerated().map {
        .paragraph(text: $0.element, commentCount: counts[$0.offset], commentURL: nil)
    } }
}

private struct ReferenceTypographyPage: View {
    var body: some View {
        GeometryReader { geometry in
            let config = configuration(geometry.size)
            let pages = ReaderPaginator.paginate(ReferenceTypography.blocks, configuration: config)
            if let page = pages.first {
                PageContentView(page: page, fontSize: 24, lineSpacing: 8,
                    fg: Color(red: 0.25, green: 0.24, blue: 0.21),
                    bg: Color(red: 0.98, green: 0.96, blue: 0.91), title: "1、归零",
                    pageNumber: 1, pageCount: pages.count, onTapComment: { _ in },
                    paragraphSpacing: 8, leftMargin: 16, rightMargin: 16,
                    topMargin: 90, bottomMargin: 30, showsChapterTitle: true)
            }
        }.ignoresSafeArea()
    }
    private func configuration(_ size: CGSize) -> ReaderPaginator.Configuration {
        var value = ReaderPaginator.Configuration(pageSize: size, fontSize: 24, lineSpacing: 8,
            paragraphSpacing: 8, leftInset: 16, rightInset: 16, topInset: 90, bottomInset: 30)
        value.chapterTitle = "1、归零"
        return value
    }
}
