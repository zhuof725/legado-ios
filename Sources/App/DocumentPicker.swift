import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// UIKit 的 UIDocumentPickerViewController 封装，用于导入书源文件（.json / .txt 等）。
/// 使用 asCopy: true，系统会把文件复制到 App 的临时目录，避免安全作用域访问问题。
struct DocumentPicker: UIViewControllerRepresentable {
    var contentTypes: [UTType] = [.json, .plainText, .text, .data]
    var allowsMultiple: Bool = true
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }

    /// 读取文件文本，依次尝试 UTF-8、GB18030、UTF-16。
    static func readText(_ url: URL) -> String? {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: AnalyzeUrl.encoding("gbk")) { return s }
        return String(data: data, encoding: .utf16)
    }
}
