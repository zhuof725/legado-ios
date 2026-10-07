import SwiftUI

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var keyword = ""
    @State private var results: [Book] = []
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
            ForEach(results) { b in
                NavigationLink {
                    BookDetailView(book: b)
                } label: {
                    BookRow(book: b, subtitle: "来源：" + b.originName)
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
        results = []
        let sources = store.sources.filter { $0.isEnabled && !($0.searchUrl ?? "").isEmpty }
        if sources.isEmpty { progress = "没有可用书源，请先导入书源"; return }
        searching = true
        progress = "0/\(sources.count)"
        task = Task {
            var done = 0
            await withTaskGroup(of: [Book].self) { group in
                var iter = sources.makeIterator()
                func addNext() {
                    if let s = iter.next() {
                        group.addTask { (try? await WebBook.search(source: s, key: key)) ?? [] }
                    }
                }
                for _ in 0..<8 { addNext() }
                for await list in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    done += 1
                    let exact = list.filter { $0.name.contains(key) || $0.author.contains(key) }
                    results.append(contentsOf: exact.isEmpty ? list.prefix(5).map { $0 } : exact)
                    progress = "\(done)/\(sources.count)，找到 \(results.count) 条"
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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 1).id("top")
                        if !chapters.isEmpty, index < chapters.count {
                            Text(chapters[index].title).font(.title3.bold())
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity) }
                        if let e = error { Text(e).foregroundStyle(.red) }
                        Text(text)
                            .font(.system(size: settings.fontSize))
                            .lineSpacing(settings.lineSpacing)
                            .textSelection(.enabled)
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
                }
                .onChange(of: index) { _ in proxy.scrollTo("top", anchor: .top) }
            }
            .onTapGesture { withAnimation { showBars.toggle() } }
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
        await loadContent()
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
        if let cached = store.cachedContent(c) { text = cached; loading = false; prefetch(s); return }
        loading = true
        text = ""
        do {
            let next = index + 1 < chapters.count ? chapters[index + 1].url : nil
            let t = try await WebBook.content(source: s, chapter: c, nextChapterUrl: next, book: book)
            text = t.isEmpty ? "（正文为空，书源可能不兼容）" : t
            store.saveContent(c, t)
        } catch {
            self.error = "正文加载失败：\(error.localizedDescription)"
        }
        loading = false
        prefetch(s)
    }

    private func prefetch(_ s: BookSource) {
        let i = index + 1
        guard i < chapters.count else { return }
        let c = chapters[i]
        if store.cachedContent(c) != nil { return }
        let next = i + 1 < chapters.count ? chapters[i + 1].url : nil
        Task {
            if let t = try? await WebBook.content(source: s, chapter: c, nextChapterUrl: next, book: book) { store.saveContent(c, t) }
        }
    }
}
