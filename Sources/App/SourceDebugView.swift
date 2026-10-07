import SwiftUI
import UIKit

struct SourceDebugView: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = "斗罗大陆"
    @State private var bookURL = ""
    @State private var report = "输入关键词后开始调试。\n此页面只运行一个书源，不读取旧目录缓存。"
    @State private var running = false
    @State private var runTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text(source.bookSourceName).font(.headline).padding(.top)
                TextField("搜索关键词", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .disabled(running)
                TextField("可选：书籍详情网址（用来直接查目录）", text: $bookURL)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(running)
                HStack {
                    Button(running ? "正在诊断…" : "开始调试") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || (keyword.trimmingCharacters(in: .whitespaces).isEmpty && bookURL.isEmpty))
                    if running { ProgressView() }
                    Spacer()
                    Button("复制日志") { UIPasteboard.general.string = report }
                }
                Text("日志只在本机内存里，不上传；请求头、Cookie、正文不记录。可截图或复制给我分析。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(report)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)
            .navigationTitle("书源调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { runTask?.cancel(); DebugLog.end(); dismiss() }
                }
            }
            .task {
                while !Task.isCancelled {
                    if running { report = DebugLog.snapshot() }
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
                }
            }
            .onDisappear { runTask?.cancel(); DebugLog.end() }
        }
    }

    private func start() {
        running = true
        DebugLog.begin()
        report = "正在调试…"
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = bookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        runTask = Task {
            await SourceDiagnostics.run(source: source, keyword: key, bookURL: url)
            report = DebugLog.snapshot()
            running = false
            DebugLog.end()
        }
    }
}
