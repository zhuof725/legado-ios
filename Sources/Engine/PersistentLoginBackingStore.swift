import Foundation

/// 登录信息的磁盘后端：单个 JSON 文件（键 -> 值），原子写入。
/// - 只存在 App 沙盒的 Application Support 下，开启文件保护，并排除 iCloud/设备备份。
/// - 值为明文（与内存后端一致，不伪造加密）；读写失败时静默退化，不输出任何值。
/// - 文件损坏时视为空，下一次写入会覆盖。
final class PersistentLoginBackingStore: SourceLoginBackingStore {
    private let fileURL: URL
    private let lock = NSLock()
    private var values: [String: String]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            values = obj
        } else {
            values = [:]
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LegadoLogin", isDirectory: true)
            .appendingPathComponent("login-store.json")
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
        persist()
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard values.removeValue(forKey: key) != nil else { return }
        persist()
    }

    /// 调用方已持锁。
    private func persist() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
            var u = fileURL
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true
            try? u.setResourceValues(rv)
        } catch {
            // 写盘失败：内存值仍有效，本次进程内不受影响。
        }
    }
}
