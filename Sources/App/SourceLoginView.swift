import SwiftUI
import WebKit

/// 书源登录：有 loginUi 时按表单登录；只有网页登录地址时用 WebView 登录并回流 Cookie。
struct SourceLoginView: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var fields: [LoginField] = []
    @State private var values: [String: String] = [:]
    @State private var message = ""
    @State private var busy = false
    @State private var showWeb = false
    @State private var loaded = false

    private var script: String? { SourceLoginForm.loginScript(source.loginUrl) }
    private var pageURL: String? { SourceLoginForm.loginPageURL(source) }
    private var hasLoginFunction: Bool { (script ?? "").contains("login") }

    var body: some View {
        NavigationStack {
            Form {
                if !fields.isEmpty {
                    Section("登录信息") {
                        ForEach(fields.filter { $0.kind != .button }) { f in
                            if f.kind == .password {
                                SecureField(f.name, text: binding(f.name))
                            } else {
                                HStack {
                                    Text(f.name).foregroundStyle(.secondary).font(.callout)
                                    TextField(f.name, text: binding(f.name))
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                }
                            }
                        }
                    }
                    let buttons = fields.filter { $0.kind == .button }
                    if !buttons.isEmpty {
                        Section("操作") {
                            ForEach(buttons) { f in
                                Button(f.name) { press(f) }.disabled(busy)
                            }
                        }
                    }
                    Section {
                        Button("保存") { save(runLogin: false) }.disabled(busy)
                        if hasLoginFunction {
                            Button("登录") { save(runLogin: true) }.disabled(busy)
                        }
                        Button("清除登录信息", role: .destructive) { clear() }.disabled(busy)
                    }
                }
                if let url = pageURL {
                    Section("网页登录") {
                        Button("打开登录页面") { showWeb = true }
                        Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                if fields.isEmpty && pageURL == nil {
                    Text("这个书源没有可用的登录配置（没有 loginUi，loginUrl 也不是网址）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty {
                    Section("结果") { Text(message).font(.footnote).textSelection(.enabled) }
                }
            }
            .navigationTitle(source.bookSourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .overlay { if busy { ProgressView() } }
            .sheet(isPresented: $showWeb) {
                WebLoginSheet(url: pageURL ?? source.bookSourceUrl, host: URL(string: pageURL ?? "")?.host,
                              cookieJar: source.cookieJarEnabled) { showWeb = false }
            }
        }
        .task { if !loaded { loaded = true; await prepare() } }
        .onAppear {
            ToastCenter.setHandler { m in DispatchQueue.main.async { message = m } }
            ToastCenter.setBrowserHandler { u, _ in
                DispatchQueue.main.async { if let url = URL(string: u) { openURL(url) } }
            }
        }
        .onDisappear { ToastCenter.setHandler(nil); ToastCenter.setBrowserHandler(nil) }
    }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private var sourceKey: String { source.bookSourceUrl }

    private func prepare() async {
        let src = source
        let text = await Task.detached { () -> String? in
            SourceLoginForm.resolveUiText(src.loginUi) { js in
                JSEngine.shared.evalString(js, context: RuleContext(source: src))
            }
        }.value
        let parsed = SourceLoginForm.parseFields(text)
        fields = parsed
        // 读取已保存的登录信息；没有保存时不写入默认值，保存由用户点击触发。
        let saved = JSEngine.loginStore.getLoginInfo(sourceKey)
            .flatMap { SourceLoginJSON.parseStringMap($0, nested: .compactJSON) } ?? [:]
        values = SourceLoginForm.initialValues(fields: parsed, saved: saved)
    }

    private func save(runLogin: Bool) {
        JSEngine.loginStore.putLoginInfo(sourceKey, SourceLoginForm.encode(values))
        message = "已保存"
        if runLogin { runScript("login()") }
    }

    private func clear() {
        JSEngine.loginStore.removeLoginInfo(sourceKey)
        try? JSEngine.loginStore.removeLoginHeader(sourceKey)
        for f in fields where f.kind != .button { values[f.name] = f.defaultValue }
        message = "已清除本书源保存的登录信息"
    }

    private func press(_ f: LoginField) {
        // 先保存当前输入，脚本里的 getLoginInfoMap() 才能读到最新值。
        JSEngine.loginStore.putLoginInfo(sourceKey, SourceLoginForm.encode(values))
        let action = f.action.trimmingCharacters(in: .whitespacesAndNewlines)
        if action.isEmpty { message = "按钮没有配置动作"; return }
        if SourceLoginForm.isURL(action) {
            if let url = URL(string: action) { openURL(url) }
            return
        }
        runScript(action)
    }

    private func runScript(_ call: String) {
        guard let lib = script else { message = "loginUrl 里没有可执行的脚本"; return }
        busy = true
        message = ""
        let src = source
        Task {
            let result = await Task.detached { JSEngine.shared.runLoginScript(source: src, library: lib, call: call) }.value
            busy = false
            switch result {
            case .failure(let e): message = "执行出错：\(e.message)"
            case .success(let s):
                if message.isEmpty { message = s.isEmpty ? "已执行" : s }
            }
        }
    }
}

/// 网页登录：用 WKWebView 打开登录页；关闭时把当前主机的 Cookie 回流到共享存储。
struct WebLoginSheet: View {
    let url: String
    let host: String?
    let cookieJar: Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            LoginWebView(url: url)
                .navigationTitle("网页登录")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            Task {
                                await WebViewLoader.syncCookiesFromWebView(host: host, enabled: cookieJar)
                                onClose()
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { onClose() } }
                }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: String

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.customUserAgent = WebViewSupport.userAgent
        if let u = URL(string: url) {
            Task {
                await WebViewLoader.syncCookiesToWebView(for: u)
                web.load(URLRequest(url: u))
            }
        }
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
