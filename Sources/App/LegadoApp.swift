import SwiftUI
import UniformTypeIdentifiers

@main
struct LegadoApp: App {
    @StateObject private var store = AppStore.shared
    @StateObject private var settings = ReadSettings()
    @State private var importMessage: String?

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { VerifyPresenter.install() }
                .environmentObject(store)
                .environmentObject(settings)
                .onOpenURL { handle($0) }
                .alert(importMessage ?? "", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                    Button("好", role: .cancel) {}
                }
        }
    }

    /// legado://import/bookSource?src=URL  or a shared .json file
    private func handle(_ url: URL) {
        if url.isFileURL {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let t = try? String(contentsOf: url, encoding: .utf8) {
                let n = (try? store.importSources(json: t)) ?? 0
                importMessage = "导入了 \(n) 个书源"
            }
            return
        }
        guard url.scheme == "legado",
              let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value else { return }
        Task {
            do { let n = try await store.importSources(from: src); importMessage = "导入了 \(n) 个书源" }
            catch { importMessage = "导入失败：\(error.localizedDescription)" }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { BookshelfView() }
                .tabItem { Label("书架", systemImage: "books.vertical") }
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { SourcesView() }
                .tabItem { Label("书源", systemImage: "square.stack.3d.up") }
        }
    }
}

// MARK: - Bookshelf

struct BookshelfView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImport = false
    @State private var importMessage: String?

    var body: some View {
        List {
            if store.books.isEmpty {
                Text("书架是空的。点右上角「+」导入 TXT / EPUB，或先到「书源」导入书源，再去「搜索」找书。")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.books.sorted { $0.lastReadAt > $1.lastReadAt }) { b in
                NavigationLink {
                    ReaderView(book: b)
                } label: {
                    BookRow(book: b, subtitle: b.durChapterTitle.map { "读到：" + $0 } ?? (b.lastChapter ?? ""))
                }
                .swipeActions {
                    Button(role: .destructive) { store.removeFromShelf(b) } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
        .navigationTitle("书架")
        .toolbar {
            Button { showImport = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showImport) {
            DocumentPicker(contentTypes: BookshelfView.localTypes, allowsMultiple: true, onPick: { urls in
                showImport = false
                importLocal(urls)
            }, onCancel: { showImport = false })
        }
        .alert("导入结果", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("好") { importMessage = nil }
        } message: { Text(importMessage ?? "") }
    }

    /// TXT 与 EPUB。EPUB 没有系统内置类型时用扩展名声明的类型兜底。
    static var localTypes: [UTType] {
        var t: [UTType] = [.plainText, .text]
        if let epub = UTType(filenameExtension: "epub") { t.append(epub) }
        t.append(.data)
        return t
    }

    private func importLocal(_ urls: [URL]) {
        var ok = 0
        var failed: [String] = []
        for u in urls {
            let access = u.startAccessingSecurityScopedResource()
            defer { if access { u.stopAccessingSecurityScopedResource() } }
            do { try store.importLocalBook(url: u); ok += 1 }
            catch LocalBookError.unsupported(let ext) { failed.append("\(u.lastPathComponent)：不支持 .\(ext)（目前支持 TXT、EPUB）") }
            catch LocalBookError.empty { failed.append("\(u.lastPathComponent)：没有读到内容") }
            catch { failed.append("\(u.lastPathComponent)：文件无法读取或已损坏") }
        }
        importMessage = "成功导入 \(ok) 本" + (failed.isEmpty ? "" : "\n\n失败：\n" + failed.joined(separator: "\n"))
    }
}

struct BookRow: View {
    let book: Book
    var subtitle: String = ""

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: book.coverUrl ?? "")) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack { Color.gray.opacity(0.2); Image(systemName: "book").foregroundStyle(.secondary) }
            }
            .frame(width: 48, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name).font(.headline).lineLimit(1)
                Text(book.author).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

// MARK: - Sources

struct SourcesView: View {
    @EnvironmentObject var store: AppStore
    @State private var showImport = false
    @State private var showFile = false
    @State private var input = ""
    @State private var message: String?
    @State private var busy = false
    @State private var debugSource: BookSource?
    @State private var loginSource: BookSource?

    var body: some View {
        List {
            Section {
                Text("共 \(store.sources.count) 个书源，启用 \(store.sources.filter { $0.isEnabled }.count) 个")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(store.sources) { s in
                HStack {
                    VStack(alignment: .leading) {
                        Text(s.bookSourceName).lineLimit(1)
                        Text(s.bookSourceGroup ?? s.bookSourceUrl).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { s.isEnabled }, set: { _ in store.toggleSource(s) })).labelsHidden()
                }
                .contentShape(Rectangle())
                .contextMenu {
                    // 只有配置了登录（loginUi 或可用的 loginUrl）的书源才显示「登录」。
                    if SourceLoginForm.hasLogin(s) {
                        Button { loginSource = s } label: { Label("登录", systemImage: "person.crop.circle") }
                    }
                    Button { debugSource = s } label: { Label("调试", systemImage: "ladybug") }
                }
            }
            .onDelete { store.deleteSources(at: $0) }
        }
        .navigationTitle("书源")
        .sheet(item: $debugSource) { source in SourceDebugView(source: source) }
        .sheet(item: $loginSource) { source in SourceLoginView(source: source) }
        .overlay { if busy { ProgressView() } }
        .toolbar {
            Menu {
                Button("网络导入 / 粘贴 JSON") { input = UIPasteboard.general.string ?? ""; showImport = true }
                Button("从文件导入") { showFile = true }
            } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showImport) {
            NavigationStack {
                TextEditor(text: $input)
                    .font(.system(.footnote, design: .monospaced))
                    .padding()
                    .navigationTitle("输入书源链接或 JSON")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { showImport = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("导入") { showImport = false; doImport(input) } }
                    }
            }
        }
        .sheet(isPresented: $showFile) {
            DocumentPicker(onPick: { urls in
                showFile = false
                importFiles(urls)
            }, onCancel: { showFile = false })
            .ignoresSafeArea()
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) {}
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var total = 0
        var failed: [String] = []
        for url in urls {
            guard let t = DocumentPicker.readText(url) else { failed.append(url.lastPathComponent); continue }
            do { total += try store.importSources(json: t) }
            catch { failed.append(url.lastPathComponent) }
        }
        var msg = "成功导入 \(total) 个书源"
        if !failed.isEmpty { msg += "\n失败文件：" + failed.joined(separator: "、") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { message = msg }
    }

    private func doImport(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let n = t.hasPrefix("http") ? try await store.importSources(from: t) : try store.importSources(json: t)
                message = "成功导入 \(n) 个书源"
            } catch {
                message = "导入失败：\(error.localizedDescription)"
            }
        }
    }
}
