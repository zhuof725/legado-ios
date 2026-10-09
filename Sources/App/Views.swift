import SwiftUI
import UIKit

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

private enum ChapterLanding {
    case start
    case end
    case saved(Int)
}

struct ReaderView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var settings: ReadSettings
    @Environment(\.dismiss) private var dismiss
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
    @State private var pageInsets = EdgeInsets()
    @State private var pageRevision = 0
    @State private var pendingEdge: Int?
    @State private var contentRequestID: UUID?
    @State private var chapterTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var pendingLanding: ChapterLanding?
    @State private var retryTarget: Int?
    @State private var retryLanding: ChapterLanding = .start
    @State private var scrollResetRevision = 0
    @State private var scrollStartPending = false
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase
    @State private var loading = true
    @State private var error: String?
    @State private var showToc = false
    @State private var showSettings = false
    @State private var showBars = false

    private func toggleBars() {
        showBars.toggle()
    }

    private func commentTapped(_ target: String?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        openComment(target)
    }

    private var theme: (bg: Color, fg: Color, name: String) {
        ReadSettings.themes[min(max(settings.theme, 0), ReadSettings.themes.count - 1)]
    }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            GeometryReader { geo in
                Color.clear.onAppear { updateViewport(geo) }
                    .onChange(of: geo.size) { _ in updateViewport(geo) }
            }.ignoresSafeArea().allowsHitTesting(false)
            if settings.pageMode == 1 {
                pagedBody
            } else {
            ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: CGFloat(settings.paragraphSpacing)) {
                            Color.clear.frame(height: 1).id("top")
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: ScrollOffsetKey.self, value: -g.frame(in: .named("reader")).minY)
                                })
                            if let volume = currentVolume {
                                VolumeTitleView(title: volume.title, foreground: theme.fg)
                                    .frame(minHeight: max(viewportHeight * 0.7, 240))
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggleBars() }
                            } else {
                                if !chapters.isEmpty, index < chapters.count {
                                    ChapterTitleView(title: chapters[index].title,
                                                     fontSize: CGFloat(settings.fontSize), color: UIColor(theme.fg))
                                        .contentShape(Rectangle())
                                        .onTapGesture { toggleBars() }
                                }
                                ForEach(Array(readingBlocks.enumerated()), id: \.offset) { _, block in
                                    blockView(block)
                                }
                            }
                            if loading { ProgressView().frame(maxWidth: .infinity) }
                            if let e = error { Text(e).foregroundStyle(.red) }
                            if !chapters.isEmpty {
                                VStack(spacing: 8) {
                                    HStack {
                                        Button("上一章") { goAcrossEdge(-1) }.disabled(previousChapter == nil || loading)
                                        Spacer()
                                        Button("下一章") { goAcrossEdge(1) }.disabled(nextChapter == nil || loading)
                                    }
                                    Text(nextChapter == nil ? "已到最后一章" : "继续上滑，自动阅读下一章")
                                        .font(.caption).foregroundStyle(theme.fg.opacity(0.5))
                                }
                                .padding(.vertical, 24)
                            }
                        }
                        .foregroundStyle(theme.fg)
                        .padding(.leading, CGFloat(settings.leftMargin))
                        .padding(.trailing, CGFloat(settings.rightMargin))
                        .padding(.top, CGFloat(settings.topMargin))
                        .padding(.bottom, CGFloat(settings.bottomMargin))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                        })
                        .background {
                            ReaderScrollBoundaryObserver(chapterID: String(index),
                                isEnabled: !loading && pendingEdge == nil && restorePermille == nil
                                    && !scrollStartPending && nextChapter != nil && retryTarget == nil
                                    && !showToc && !showSettings && commentURL == nil && !commentBusy,
                                onNext: { goAcrossEdge(1) })
                        }
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
                    .onChange(of: scrollResetRevision) { _ in
                        if restorePermille != nil {
                            applyRestoreIfReady(proxy: proxy)
                        } else {
                            let revision = scrollResetRevision
                            DispatchQueue.main.async {
                                guard revision == scrollResetRevision else { return }
                                withAnimation(nil) { proxy.scrollTo("top", anchor: .top) }
                                scrollStartPending = false
                            }
                        }
                    }
                    .onChange(of: loading) { _ in applyRestoreIfReady(proxy: proxy) }
                }
                .background {
                    theme.bg.contentShape(Rectangle()).onTapGesture { toggleBars() }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .overlay(alignment: .top) {
            if showBars {
                HStack(spacing: 18) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    Text(book.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(theme.bg.opacity(0.96))
            }
        }
        .overlay(alignment: .bottom) {
            if showBars {
                HStack {
                    Button { showToc = true } label: {
                        Label("目录", systemImage: "list.bullet")
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Label("设置", systemImage: "textformat.size")
                    }
                }
                .font(.body)
                .foregroundStyle(theme.fg)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(theme.bg.opacity(0.96))
            }
        }
        .sheet(isPresented: $showToc) {
            NavigationStack {
                ScrollViewReader { p in
                    List(chapters) { c in
                        Group {
                            if c.isVolume {
                                Button { showToc = false; go(c.index) } label: {
                                    Text(c.title).font(.headline)
                                        .foregroundStyle(c.index == index ? Color.accentColor : Color.secondary)
                                }
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
                    ReaderTypographyControls(settings: settings)
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .overlay {
            if loading && (!text.isEmpty || !blocks.isEmpty || !pages.isEmpty) {
                ZStack {
                    Color.clear.contentShape(Rectangle())
                    ProgressView("正在加载章节…")
                        .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let target = retryTarget, !loading {
                VStack(spacing: 8) {
                    Text(error ?? "章节加载失败").font(.caption).lineLimit(2)
                    HStack {
                        Button("重试加载") { loadChapter(target, landing: retryLanding) }
                        Button("留在本章") { retryTarget = nil; error = nil }
                    }
                }
                .padding().frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .sheet(item: $commentURL) { link in CommentSheet(url: link) }
        .onChange(of: scenePhase) { phase in if phase != .active { store.flushProgress() } }
        .onChange(of: settings.fontSize) { _ in repaginate() }
        .onChange(of: settings.lineSpacing) { _ in repaginate() }
        .onChange(of: settings.paragraphSpacing) { _ in repaginate() }
        .onChange(of: settings.leftMargin) { _ in repaginate() }
        .onChange(of: settings.rightMargin) { _ in repaginate() }
        .onChange(of: settings.topMargin) { _ in repaginate() }
        .onChange(of: settings.bottomMargin) { _ in repaginate() }
        .onChange(of: settings.pageMode) { _ in repaginate() }
        .onChange(of: screenSize) { _ in repaginate() }
        .onDisappear {
            contentRequestID = nil
            chapterTask?.cancel()
            chapterTask = nil
            prefetchTask?.cancel()
            prefetchTask = nil
            pendingEdge = nil
            loading = false
            restorePermille = nil
            pendingLanding = nil
            scrollStartPending = false
            store.flushProgress()
        }
        .task { await start() }
    }

    private func start() async {
        if store.isLocal(book) { await startLocal(); return }
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
        let initial = min(max(index, 0), chapters.count - 1)
        guard let first = readableIndex(from: initial, direction: 1)
                ?? readableIndex(from: initial, direction: -1) else {
            error = "目录中没有可读章节"; loading = false; return
        }
        index = first
        await loadInitialChapter()
    }

    private func startLocal() async {
        index = store.books.first(where: { $0.bookUrl == book.bookUrl })?.durChapterIndex ?? book.durChapterIndex
        guard let toc = store.localToc(book), !toc.isEmpty else { error = "本地书文件已丢失，请重新导入"; loading = false; return }
        chapters = toc
        index = min(max(index, 0), toc.count - 1)
        await loadInitialChapter()
    }

    private func loadInitialChapter() async {
        let saved = store.scrollPosition(book)
        let requestID = UUID()
        contentRequestID = requestID
        loading = true
        await loadContent(at: index, landing: saved > 0 ? .saved(saved) : .start, requestID: requestID)
    }

    /// 记录滚动位置（千分比）。内容还没排好、或正在恢复位置时不记录，避免把 0 写回去覆盖已存的位置。
    private func recordScroll(_ offset: CGFloat) {
        guard !loading, restorePermille == nil, !scrollStartPending, retryTarget == nil else { return }
        let scrollable = contentHeight - viewportHeight
        guard scrollable > 40 else { return }
        let p = Int((min(max(offset, 0), scrollable) / scrollable) * 1000)
        store.updateScrollPosition(book, permille: p)
    }

    /// 内容加载并排版完成后，滚到上次保存的位置（只恢复一次）。
    private func applyRestoreIfReady(proxy: ScrollViewProxy) {
        guard let target = restorePermille, !loading, viewportHeight > 0, contentHeight > 0 else { return }
        let chapter = index
        let revision = scrollResetRevision
        let slot = min(max(Int((Double(target) / 10).rounded()), 0), 100)
        DispatchQueue.main.async {
            guard chapter == index, revision == scrollResetRevision, restorePermille == target else { return }
            withAnimation(nil) {
                proxy.scrollTo(contentHeight > viewportHeight + 40 ? "slot-\(slot)" : "top", anchor: .top)
            }
            restorePermille = nil
            scrollStartPending = false
        }
    }

    // MARK: 翻页模式

    private var turnStyle: PageTurnStyle { PageTurnStyle(rawValue: settings.pageTurnStyle) ?? .slide }

    /// 重新分页：字号、行距、屏幕尺寸或内容变化时调用，并回到同一个字符位置。
    private func repaginate(keepOffset: Int? = nil) {
        guard settings.pageMode == 1, screenSize.width > 0 else { return }
        if currentVolume != nil {
            pages = [BookPage(blocks: [], startOffset: 0)]
            pageRevision += 1
            pageIndex = 0
            pendingLanding = nil
            return
        }
        let source = readingBlocks
        guard !source.isEmpty else { pages = []; return }
        let offset = keepOffset ?? (pages.indices.contains(pageIndex) ? pages[pageIndex].startOffset : 0)
        let configuration = ReaderPaginator.Configuration(
            pageSize: screenSize,
            safeInsets: UIEdgeInsets(top: pageInsets.top, left: pageInsets.leading,
                                     bottom: pageInsets.bottom, right: pageInsets.trailing),
            fontSize: CGFloat(settings.fontSize),
            lineSpacing: CGFloat(settings.lineSpacing),
            paragraphSpacing: CGFloat(settings.paragraphSpacing),
            leftInset: CGFloat(settings.leftMargin),
            rightInset: CGFloat(settings.rightMargin),
            topInset: CGFloat(settings.topMargin),
            bottomInset: CGFloat(settings.bottomMargin),
            chapterTitle: chapters.indices.contains(index) ? chapters[index].title : "")
        pages = ReaderPaginator.paginate(source, configuration: configuration)
        pageRevision += 1
        pageIndex = Paginator.pageIndex(containing: offset, in: pages)
        if !pages.isEmpty, let landing = pendingLanding {
            switch landing {
            case .start: pageIndex = 0
            case .end: pageIndex = pages.count - 1
            case .saved(let permille):
                let total = max((pages.last?.startOffset ?? 0) + 1, 1)
                pageIndex = Paginator.pageIndex(containing: Int(Double(total) * Double(permille) / 1000), in: pages)
            }
            pendingLanding = nil
        }
    }

    private var currentVolume: BookChapter? {
        guard chapters.indices.contains(index), chapters[index].isVolume else { return nil }
        return chapters[index]
    }

    private var readingBlocks: [ContentBlock] {
        blocks.isEmpty ? Paginator.blocks(fromPlain: text) : blocks
    }

    private func updateViewport(_ geo: GeometryProxy) {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let safe = window?.safeAreaInsets ?? .zero
        pageInsets = EdgeInsets(top: safe.top, leading: safe.left, bottom: safe.bottom, trailing: safe.right)
        screenSize = geo.size
    }

    private var renderedPages: [AnyView] {
        pages.enumerated().map { i, page in
            AnyView(PageContentView(page: page, fontSize: settings.fontSize,
                lineSpacing: settings.lineSpacing, fg: theme.fg, bg: theme.bg,
                title: chapters.indices.contains(index) ? chapters[index].title : "",
                pageNumber: i + 1, pageCount: pages.count,
                onTapComment: { commentTapped($0) }, safeInsets: pageInsets,
                paragraphSpacing: settings.paragraphSpacing,
                leftMargin: settings.leftMargin, rightMargin: settings.rightMargin,
                topMargin: settings.topMargin, bottomMargin: settings.bottomMargin,
                volumeTitle: currentVolume?.title,
                showsChapterTitle: currentVolume == nil).ignoresSafeArea())
        }
    }

    @ViewBuilder
    private var pageTurnContainer: some View {
        if turnStyle == .slide || turnStyle == .curl {
            PageTurnView(pages: renderedPages, current: $pageIndex, style: turnStyle,
                         background: UIColor(theme.bg),
                         onEdge: { dir in DispatchQueue.main.async { goAcrossEdge(dir) } },
                         onTapCenter: { toggleBars() })
        } else {
            InteractivePageTurnView(pages: renderedPages, current: $pageIndex, style: .fade,
                                    onEdge: { goAcrossEdge($0) },
                                    onTapCenter: { toggleBars() })
        }
    }

    @ViewBuilder
    private var pagedBody: some View {
        if pages.isEmpty {
            VStack { if loading { ProgressView() } else if let e = error { Text(e).foregroundStyle(.red) } else { Text("") } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { toggleBars() }
        } else {
            pageTurnContainer
                .id("\(settings.pageTurnStyle)-\(pageRevision)-\(index)-\(settings.theme)")
                .ignoresSafeArea()
                .onChange(of: pageIndex) { i in recordPage(i) }
        }
    }

    /// 翻页模式的位置 = 当前页第一个字的字符偏移；换算成千分比存进已有的 durChapterPos，滚动模式也能读。
    private func recordPage(_ i: Int) {
        guard !loading, retryTarget == nil, pages.indices.contains(i), let last = pages.last else { return }
        let total = max(last.startOffset + 1, 1)
        store.updateScrollPosition(book, permille: Int(Double(pages[i].startOffset) / Double(total) * 1000))
    }

    private var nextChapter: Int? { readableIndex(from: index + 1, direction: 1) }
    private var previousChapter: Int? { readableIndex(from: index - 1, direction: -1) }

    private func goAcrossEdge(_ dir: Int) {
        guard !loading, pendingEdge == nil, !showToc, !showSettings, commentURL == nil, !commentBusy else { return }
        let step = dir > 0 ? 1 : -1
        guard let target = readableIndex(from: index + step, direction: step) else { return }
        // 必须直到这次请求成功/失败才解锁，不能用固定 0.6 秒窗口。
        pendingEdge = step
        loadChapter(target, landing: step < 0 && settings.pageMode == 1 ? .end : .start)
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
            InlineCommentParagraph(text: t, count: count,
                                    fontSize: settings.fontSize,
                                    lineSpacing: settings.lineSpacing,
                                    color: UIColor(theme.fg),
                                    onTextTap: { toggleBars() },
                                    onTap: { commentTapped(url) })
                .frame(maxWidth: .infinity, alignment: .leading)
        case .inlineBubble:
            EmptyView()
        case .image(let src, let click):
            ContentImageView(src: src)
                .onTapGesture { commentTapped(click) }
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
            .onTapGesture { commentTapped(click) }
        case .chapterComments(let title, let count, _, let click):
            HStack {
                Text(title).font(.system(size: settings.fontSize - 2, weight: .bold))
                Spacer()
                Text(count).font(.system(size: settings.fontSize - 4)).foregroundStyle(theme.fg.opacity(0.7))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.fg.opacity(0.07)))
            .contentShape(Rectangle())
            .onTapGesture { commentTapped(click) }
        }
    }

    private func readableIndex(from value: Int, direction: Int) -> Int? {
        ChapterNavigation.displayIndex(from: value, direction: direction, chapters: chapters)
    }

    private func go(_ i: Int) {
        guard !loading, let target = readableIndex(from: i, direction: i >= index ? 1 : -1) else { return }
        loadChapter(target, landing: .start)
    }

    private func loadChapter(_ target: Int, landing: ChapterLanding) {
        guard !loading, chapters.indices.contains(target) else { return }
        chapterTask?.cancel()
        // 停止旧预读队列的后续任务；在途的目标章由共享缓存接管，不会重复抓取。
        prefetchTask?.cancel()
        prefetchTask = nil
        let requestID = UUID()
        contentRequestID = requestID
        retryTarget = nil
        error = nil
        // 同一主线程回调立即上锁；不等 Task 启动后才设置 loading。
        loading = true
        chapterTask = Task { await loadContent(at: target, landing: landing, requestID: requestID) }
    }

    private func loadContent(at target: Int, landing: ChapterLanding, requestID: UUID) async {
        defer {
            if contentRequestID == requestID {
                contentRequestID = nil
                loading = false
                pendingEdge = nil
                chapterTask = nil
            }
        }
        guard chapters.indices.contains(target), contentRequestID == requestID else { return }
        let chapter = chapters[target]
        do {
            let raw: String
            if chapter.isVolume {
                // 卷标题是独立的本地阅读项，不当成空章节，也不请求卷链接。
                raw = chapter.title
            } else if store.isLocal(book) {
                guard let local = store.localContent(book, index: target) else {
                    throw NSError(domain: "Reader", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "本地章节文件不存在"])
                }
                raw = local.isEmpty ? "（本章没有内容）" : local
            } else {
                guard let source = store.source(for: book.origin) else {
                    throw NSError(domain: "Reader", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到书源"])
                }
                let next = ChapterNavigation.contentIndex(from: target + 1, direction: 1, chapters: chapters)
                    .map { chapters[$0].url }
                raw = try await ChapterContentLoader.content(source: source, book: book, chapter: chapter,
                                                             nextChapterURL: next)
            }
            try Task.checkCancellation()
            guard contentRequestID == requestID else { return }
            // 网络失败时不改章号、不清旧文、不覆盖已保存的阅读位置。
            index = target
            retryTarget = nil
            error = nil
            show(raw: raw, landing: landing)
            store.updateProgress(book, index: target, title: chapter.title)
            if settings.pageMode == 1, pages.indices.contains(pageIndex) {
                let total = max((pages.last?.startOffset ?? 0) + 1, 1)
                store.updateScrollPosition(book, permille: Int(Double(pages[pageIndex].startOffset) / Double(total) * 1000))
            } else {
                let position: Int
                switch landing {
                case .start: position = 0
                case .end: position = 1000
                case .saved(let value): position = value
                }
                store.updateScrollPosition(book, permille: position)
            }
            if let source = store.source(for: book.origin) { prefetch(source) }
        } catch is CancellationError {
            // 离开阅读器后不再呈现旧请求的错误。
        } catch {
            guard contentRequestID == requestID else { return }
            self.error = "正文加载失败：\(error.localizedDescription)"
            retryTarget = target
            retryLanding = landing
        }
    }

    /// 缓存里存的是规则输出的原始文本（可能带 <comment>/<img>）；旧缓存是纯文本，同样能解析。
    private func show(raw: String, landing: ChapterLanding) {
        let parsed = ContentBlocks.parse(raw)
        let hasRich = parsed.contains { if case .paragraph(_, let c, _) = $0 { return c > 0 }; if case .paragraph = $0 { return false }; return true }
        if currentVolume != nil { blocks = []; text = raw }
        else if hasRich { blocks = parsed; text = "" }
        else { blocks = []; text = WebBook.cleanText(raw) }
        pages = []
        pageIndex = 0
        restorePermille = nil
        if settings.pageMode == 1 {
            pendingLanding = landing
            repaginate(keepOffset: 0)
        } else {
            pendingLanding = nil
            switch landing {
            case .start: break
            case .end: restorePermille = 1000
            case .saved(let position): restorePermille = position
            }
            // 等 SwiftUI 排好新章后再恢复，禁止旧章惯性驱动下一次换章。
            scrollStartPending = true
            scrollResetRevision += 1
        }
    }

    private func prefetch(_ source: BookSource) {
        prefetchTask?.cancel()
        guard !store.isLocal(book) else { return }
        let snapshot = chapters
        let queue = ChapterNavigation.prefetchIndices(after: index, chapters: snapshot, limit: 3)
        guard !queue.isEmpty else { prefetchTask = nil; return }
        let readingBook = book
        // 阅读时在 MainActor 外依次预读后续 3 章，避免同时轰击书源或阻塞正文手势。
        prefetchTask = Task.detached(priority: .utility) {
            for i in queue {
                guard !Task.isCancelled else { return }
                let next = ChapterNavigation.contentIndex(from: i + 1, direction: 1, chapters: snapshot)
                    .map { snapshot[$0].url }
                do {
                    _ = try await ChapterContentLoader.content(source: source, book: readingBook,
                        chapter: snapshot[i], nextChapterURL: next, priority: .utility)
                } catch {
                    // 不把预读失败展示成当前章错误，也不越过登录/网络失败继续请求后续章节。
                    return
                }
            }
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
