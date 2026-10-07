import SwiftUI

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var keyword = ""
    @State private var hits: [SearchHit] = []
    @State private var failedCount = 0
    @State private var searching = false
    @State private var progress = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            if searching || !progress.isEmpty {
                HStack {
                    if searching { ProgressView() }
                    Text(progress).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(hits) { h in
                NavigationLink {
                    BookDetailView(book: h.book)
                } label: {
                    BookRow(book: h.book, subtitle: h.sourceCount > 1
                            ? "来源：\(h.book.originName) 等 \(h.sourceCount) 个书源"
                            : "来源：" + h.book.originName)
                }
            }
        }
        .navigationTitle("搜索")
        .searchable(text: $keyword, prompt: "书名或作者")
        .onSubmit(of: .search) { start() }
        .toolbar {
            if searching { Button("停止") { task?.cancel(); searching = false } }
        }
    }

    private func start() {
        let key = keyword.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        task?.cancel()
        hits = []
        failedCount = 0
        let sources = store.sources.filter { $0.isEnabled && !($0.searchUrl ?? "").isEmpty }
        if sources.isEmpty { progress = "没有可用书源，请先导入书源"; return }
        searching = true
        progress = "0/\(sources.count)"
        task = Task {
            var done = 0
            await withTaskGroup(of: ([Book], Bool).self) { group in
                var iter = sources.makeIterator()
                func addNext() {
                    if let s = iter.next() {
                        group.addTask {
                            do { return (try await WebBook.search(source: s, key: key), false) }
                            catch { return ([], true) }
                        }
                    }
                }
                for _ in 0..<8 { addNext() }
                for await (list, failed) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    done += 1
                    if failed { failedCount += 1 }
                    // 与书名/作者都不相关的结果只在没有相关结果时才保留少量，避免淹没真正的匹配。
                    let related = list.filter { SearchRanking.rank(name: $0.name, author: $0.author, key: key) < 4 }
                    hits = SearchRanking.merge(existing: hits, new: related.isEmpty ? Array(list.prefix(3)) : related, key: key)
                    progress = "\(done)/\(sources.count)，找到 \(hits.count) 本" + (failedCount > 0 ? "，\(failedCount) 个书源失败" : "")
                    addNext()
                }
            }
            searching = false
        }
    }
}

// MARK: - Detail

struct BookDetailView: View {
    @EnvironmentObject var store: AppStore
    @State var book: Book
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                BookRow(book: book, subtitle: book.kind ?? "")
                if let w = book.wordCount { Text("字数：" + w).font(.footnote) }
                if let l = book.lastChapter { Text("最新：" + l).font(.footnote) }
                Text("来源：" + book.originName).font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView() }
            if let e = error { Text(e).foregroundStyle(.red).font(.footnote) }
            if let intro = book.intro {
                Section("简介") { Text(intro).font(.callout) }
            }
            Section {
                NavigationLink("开始阅读") { ReaderView(book: book) }
                if store.isOnShelf(book) {
                    Button("移出书架", role: .destructive) { store.removeFromShelf(book) }
                } else {
                    Button("加入书架") { store.addToShelf(book) }
                }
            }
        }
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        guard let s = store.source(for: book.origin) else { error = "找不到书源"; return }
        do {
            let b = try await WebBook.bookInfo(source: s, book: book)
            var nb = b
            if let old = store.books.first(where: { $0.bookUrl == b.bookUrl }) {
                nb.durChapterIndex = old.durChapterIndex
                nb.durChapterTitle = old.durChapterTitle
                store.addToShelf(nb)
            }
            book = nb
        } catch {
            self.error = "详情加载失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Reader

struct ReaderView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: ReadSettings
    let book: Book

    @State private var chapters: [BookChapter] = []
    @State private var index = 0
    @State private var text = ""
    @State private var blocks: [ContentBlock] = []
    @State private var commentURL: URL?
    @State private var commentBusy = false
    @State private var restorePermille: Int?
    @State private var pages: [BookPage] = []
    @State private var pageIndex = 0
    @State private var screenSize: CGSize = .zero
    @State private var pendingEdge: Int?
    @State private var pendingLastPage = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var loading = true
    @State private var error: String?
    @State private var showToc = false
    @State private var showSettings = false
    @State private var showBars = false

    private var theme: (bg: Color, fg: Color, name: String) {
        ReadSettings.themes[min(max(settings.theme, 0), ReadSettings.themes.count - 1)]
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            GeometryReader { geo in
                Color.clear.onAppear { screenSize = geo.size }
                    .onChange(of: geo.size) { screenSize = $0 }
            }
            if settings.pageMode == 1 {
                pagedBody
            } else {
            ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
                            Color.clear.frame(height: 1).id("top")
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("reader")).minY)
                                })
                            if !chapters.isEmpty, index < chapters.count {
                                Text(chapters[index].title).font(.title3.bold())
                            }
                            if loading { ProgressView().frame(maxWidth: .infinity) }
                            if let e = error { Text(e).foregroundStyle(.red) }
                            if blocks.isEmpty {
                                Text(text)
                                    .font(.system(size: settings.fontSize))
                                    .lineSpacing(settings.lineSpacing)
                                    .textSelection(.enabled)
                            } else {
                                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                    blockView(block)
                                }
                            }
                            if !chapters.isEmpty {
                                HStack {
                                    Button("上一章") { go(index - 1) }.disabled(index <= 0)
                                    Spacer()
                                    Button("下一章") { go(index + 1) }.disabled(index >= chapters.count - 1)
                                }
                                .padding(.vertical, 24)
                            }
                        }
                        .foregroundStyle(theme.fg)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                        // 等间距透明锚点：位置恢复时按比例选一个滚过去。锚点只占背景，不影响排版。
                        .background(alignment: .top) {
                            GeometryReader { g in
                                let scrollable = max(g.size.height - viewportHeight, 0)
                                ZStack(alignment: .top) {
                                    ForEach(0...100, id: \.self) { i in
                                        Color.clear.frame(width: 1, height: 1)
                                            .offset(y: scrollable * CGFloat(i) / 100)
                                            .id("slot-\(i)")
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                            }
                        }
                    }
                    .coordinateSpace(name: "reader")
                    .background(GeometryReader { g in
                        Color.clear.preference(key: ViewportHeightKey.self, value: g.size.height)
                    })
                    .onPreferenceChange(ContentHeightKey.self) { h in
                        contentHeight = h
                        applyRestoreIfReady(proxy: proxy)
                    }
                    .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
                    .onPreferenceChange(ScrollOffsetKey.self) { offset in recordScroll(offset) }
                    .onChange(of: index) { _ in
                        restorePermille = nil
                        proxy.scrollTo("top", anchor: .top)
                    }
                    .onChange(of: loading) { _ in applyRestoreIfReady(proxy: proxy) }
                }
                .onTapGesture { withAnimation { showBars.toggle() } }
            }
        }
        .navigationTitle(showBars ? book.name : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showBars ? .visible : .hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if showBars {
                    Button { showToc = true } label: { Label("目录", systemImage: "list.bullet") }
                    Spacer()
                    Button { showSettings = true } label: { Label("设置", systemImage: "textformat.size") }
                }
            }
        }
        .sheet(isPresented: $showToc) {
            NavigationStack {
                ScrollViewReader { p in
                    List(chapters) { c in
                        Group {
                            if c.isVolume {
                                Text(c.title)
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                    .listRowBackground(Color.clear)
                            } else {
                                Button {
                                    showToc = false; go(c.index)
                                } label: {
                                    HStack {
                                        Text(c.title).foregroundStyle(c.index == index ? Color.accentColor : Color.primary)
                                        if c.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                        .id(c.index)
                    }
                    .onAppear { p.scrollTo(index, anchor: .center) }
                }
                .navigationTitle("目录（\(chapters.count)）")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("阅读方式") {
                        Picker("方式", selection: $settings.pageMode) {
                            Text("滚动").tag(0)
                            Text("翻页").tag(1)
                        }
                        .pickerStyle(.segmented)
                        if settings.pageMode == 1 {
                            Picker("翻页动画", selection: $settings.pageTurnStyle) {
                                ForEach(PageTurnStyle.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    Section("字号 \(Int(settings.fontSize))") { Slider(value: $settings.fontSize, in: 12...32, step: 1) }
                    Section("行距 \(Int(settings.lineSpacing))") { Slider(value: $settings.lineSpacing, in: 0...24, step: 1) }
                    Section("背景") {
                        Picker("主题", selection: $settings.theme) {
                            ForEach(0..<ReadSettings.themes.count, id: \.self) { Text(ReadSettings.themes[$0].name).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .navigationTitle("阅读设置")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $commentURL) { link in CommentSheet(url: link) }
        .onChange(of: scenePhase) { phase in if phase != .active { store.flushProgress() } }
        .onChange(of: settings.fontSize) { _ in repaginate() }
        .onChange(of: settings.lineSpacing) { _ in repaginate() }
        .onChange(of: settings.pageMode) { _ in repaginate() }
        .onChange(of: screenSize) { _ in repaginate() }
        .onDisappear { store.flushProgress() }
        .task { await start() }
    }

    private func start() async {
        guard let s = store.source(for: book.origin) else { error = "找不到书源"; loading = false; return }
        index = store.books.first(where: { $0.bookUrl == book.bookUrl })?.durChapterIndex ?? book.durChapterIndex
        if let c = store.cachedToc(book), !c.isEmpty {
            chapters = c
        } else {
            do {
                var b = book
                if b.tocUrl == nil { b = try await WebBook.bookInfo(source: s, book: b) }
                chapters = try await WebBook.chapters(source: s, book: b)
                store.saveToc(book, chapters)
            } catch {
                self.error = "目录加载失败：\(error.localizedDescription)"
                loading = false
                return
            }
        }
        if chapters.isEmpty { error = "目录为空，书源可能不兼容"; loading = false; return }
        index = readableIndex(from: index, direction: 1) ?? 0
        restorePermille = store.scrollPosition(book) > 0 ? store.scrollPosition(book) : nil
        await loadContent()
    }

    /// 记录滚动位置（千分比）。内容还没排好、或正在恢复位置时不记录，避免把 0 写回去覆盖已存的位置。
    private func recordScroll(_ offset: CGFloat) {
        guard !loading, restorePermille == nil else { return }
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 40 else { return }
        let p = Int((min(max(offset, 0), scrollable) / scrollable) * 1000)
        store.updateScrollPosition(book, permille: p)
    }

    /// 内容加载并排版完成后，滚到上次保存的位置（只恢复一次）。
    private func applyRestoreIfReady(proxy: ScrollViewProxy) {
        guard let target = restorePermille, !loading, contentHeight > viewportHeight + 40 else { return }
        restorePermille = nil
        // 内容后面铺了 101 个等间距的透明锚点（0...100），选最接近的一个，把它对齐到视口顶部。
        let slot = min(max(Int((Double(target) / 10).rounded()), 0), 100)
        DispatchQueue.main.async {
            withAnimation(nil) { proxy.scrollTo("slot-\(slot)", anchor: .top) }
        }
    }

    // MARK: 翻页模式

    private var turnStyle: PageTurnStyle { PageTurnStyle(rawValue: settings.pageTurnStyle) ?? .slide }

    /// 重新分页：字号、行距、屏幕尺寸或内容变化时调用，并回到同一个字符位置。
    private func repaginate(keepOffset: Int? = nil) {
        guard settings.pageMode == 1, screenSize.width > 0 else { return }
        let source: [ContentBlock] = blocks.isEmpty ? Paginator.blocks(fromPlain: text) : blocks
        guard !source.isEmpty else { pages = []; return }
        let offset = keepOffset ?? (pages.indices.contains(pageIndex) ? pages[pageIndex].startOffset : 0)
        let layout = Paginator.layout(width: screenSize.width, height: screenSize.height,
                                      fontSize: settings.fontSize, lineSpacing: settings.lineSpacing)
        pages = Paginator.paginate(source, layout: layout)
        pageIndex = Paginator.pageIndex(containing: offset, in: pages)
    }

    @ViewBuilder
    private var pagedBody: some View {
        if pages.isEmpty {
            VStack { if loading { ProgressView() } else if let e = error { Text(e).foregroundStyle(.red) } else { Text("") } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { withAnimation { showBars.toggle() } }
        } else {
            PageTurnView(
                pages: pages.enumerated().map { i, pg in
                    AnyView(PageContentView(page: pg, fontSize: settings.fontSize, lineSpacing: settings.lineSpacing,
                                            fg: theme.fg, bg: theme.bg,
                                            title: index < chapters.count ? chapters[index].title : "",
                                            pageNumber: i + 1, pageCount: pages.count,
                                            onTapComment: { openComment($0) }))
                },
                current: $pageIndex,
                style: turnStyle,
                background: UIColor(theme.bg),
                onEdge: { dir in
                    // 翻过章首/章末：切到上一章末页或下一章首页。
                    DispatchQueue.main.async { goAcrossEdge(dir) }
                },
                onTapCenter: { withAnimation { showBars.toggle() } })
            .id("\(settings.pageTurnStyle)-\(pages.count)-\(index)-\(Int(settings.fontSize))-\(Int(settings.lineSpacing))-\(settings.theme)")
            .ignoresSafeArea(edges: .bottom)
            .onChange(of: pageIndex) { i in recordPage(i) }
        }
    }

    /// 翻页模式的位置 = 当前页第一个字的字符偏移；换算成千分比存进已有的 durChapterPos，滚动模式也能读。
    private func recordPage(_ i: Int) {
        guard pages.indices.contains(i), let last = pages.last else { return }
        let total = max(last.startOffset + 1, 1)
        store.updateScrollPosition(book, permille: Int(Double(pages[i].startOffset) / Double(total) * 1000))
    }

    private func goAcrossEdge(_ dir: Int) {
        guard pendingEdge == nil else { return }
        let target = index + dir
        guard chapters.indices.contains(target) else { return }
        pendingEdge = dir
        pendingLastPage = dir < 0
        go(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pendingEdge = nil }
    }

    /// 点击评论：网址直接弹评论页；`js:` 开头是书源函数调用，先在后台执行拿到网址。
    private func openComment(_ target: String?) {
        guard let t = target, !t.isEmpty else { return }
        if t.hasPrefix("js:") {
            guard let src = store.source(for: book.origin), !commentBusy else { return }
            commentBusy = true
            let call = String(t.dropFirst(3))
            Task {
                let url = await Task.detached { JSEngine.shared.resolveClickURL(source: src, click: call) }.value
                commentBusy = false
                if let u = url, let link = URL(string: u) { commentURL = link }
            }
        } else if let link = URL(string: t) {
            commentURL = link
        }
    }

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let t, let count, let url):
            // 段尾气泡：数字放在空心圆角气泡里，渲染成图片后接在文字末尾，随文字换行。
            let size = max(settings.fontSize - 5, 11)
            (Text("\u{3000}\u{3000}" + t)
                + (count > 0 ? Text(" ") + Text(Image(uiImage: CommentBubble.image(count: count, size: size, color: UIColor(theme.fg)))).baselineOffset(-CommentBubble.tailHeight(for: size) * 0.5) : Text("")))
                .font(.system(size: settings.fontSize))
                .lineSpacing(settings.lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if count > 0 { openComment(url) } }
        case .inlineBubble:
            EmptyView()
        case .image(let src, let click):
            ContentImageView(src: src)
                .onTapGesture { openComment(click) }
        case .hotComment(let label, let t, let click):
            HStack(spacing: 10) {
                Text(label).font(.system(size: max(settings.fontSize - 5, 11), weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 1, green: 0.27, blue: 0.27)))
                Text(t).font(.system(size: max(settings.fontSize - 3, 12))).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 22).fill(theme.fg.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(theme.fg.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { openComment(click) }
        case .chapterComments(let title, let count, _, let click):
            HStack {
                Text(title).font(.system(size: settings.fontSize - 2, weight: .bold))
                Spacer()
                Text(count).font(.system(size: settings.fontSize - 4)).foregroundStyle(theme.fg.opacity(0.7))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.fg.opacity(0.07)))
            .contentShape(Rectangle())
            .onTapGesture { openComment(click) }
        }
    }

    private func readableIndex(from value: Int, direction: Int) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var i = min(max(value, 0), chapters.count - 1)
        while chapters[i].isVolume || chapters[i].url.isEmpty {
            i += direction
            if i < 0 || i >= chapters.count { return nil }
        }
        return i
    }

    private func go(_ i: Int) {
        guard let target = readableIndex(from: i, direction: i >= index ? 1 : -1) else { return }
        index = target
        Task { await loadContent() }
    }

    private func loadContent() async {
        guard let s = store.source(for: book.origin), index < chapters.count else { return }
        let c = chapters[index]
        store.updateProgress(book, index: index, title: c.title)
        error = nil
        if let cached = store.cachedContent(c) { show(raw: cached); loading = false; prefetch(s); return }
        loading = true
        text = ""
        blocks = []
        do {
            let next = index + 1 < chapters.count ? chapters[index + 1].url : nil
            let r = try await WebBook.contentBlocks(source: s, chapter: c, nextChapterUrl: next, book: book)
            if r.raw.isEmpty { text = "（正文为空，书源可能不兼容）" } else { show(raw: r.raw) }
            store.saveContent(c, r.raw)
        } catch {
            self.error = "正文加载失败：\(error.localizedDescription)"
        }
        loading = false
        prefetch(s)
    }

    /// 缓存里存的是规则输出的原始文本（可能带 <comment>/<img>）；旧缓存是纯文本，同样能解析。
    private func show(raw: String) {
        let parsed = ContentBlocks.parse(raw)
        let hasRich = parsed.contains { if case .paragraph(_, let c, _) = $0 { return c > 0 }; if case .paragraph = $0 { return false }; return true }
        if hasRich { blocks = parsed; text = "" }
        else { blocks = []; text = WebBook.cleanText(raw) }
        // 翻页模式：按保存的位置（千分比）或上/下一章边界决定落在哪一页。
        let permille = restorePermille ?? 0
        repaginate(keepOffset: 0)
        if settings.pageMode == 1, !pages.isEmpty {
            if pendingLastPage { pageIndex = pages.count - 1; pendingLastPage = false }
            else if permille > 0, let last = pages.last { pageIndex = Paginator.pageIndex(containing: Int(Double(last.startOffset + 1) * Double(permille) / 1000), in: pages); restorePermille = nil }
            else { pageIndex = 0 }
        }
    }

    private func prefetch(_ s: BookSource) {
        let i = index + 1
        guard i < chapters.count else { return }
        let c = chapters[i]
        if store.cachedContent(c) != nil { return }
        let next = i + 1 < chapters.count ? chapters[i + 1].url : nil
        Task {
            if let r = try? await WebBook.contentBlocks(source: s, chapter: c, nextChapterUrl: next, book: book) { store.saveContent(c, r.raw) }
        }
    }
}


private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
