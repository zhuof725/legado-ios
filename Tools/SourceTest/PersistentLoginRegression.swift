import Foundation

/// 离线回归：登录信息磁盘后端。值均为合成数据，失败信息不含值。
enum PersistentLoginRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("login-reg-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("sub/login.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = PersistentLoginBackingStore(fileURL: file)
        check(a.get("userInfo_x") == nil, "持久化登录：初始为空")
        a.set("userInfo_https://a.test#1", "{\"u\":\"v1\"}")
        a.set("userInfo_https://a.test#2", "{\"u\":\"v2\"}")
        a.set("loginHeader_https://a.test#1", "{\"Cookie\":\"k=v\"}")
        check(FileManager.default.fileExists(atPath: file.path), "持久化登录：写入时自动创建目录和文件")

        let b = PersistentLoginBackingStore(fileURL: file)
        check(b.get("userInfo_https://a.test#1") == "{\"u\":\"v1\"}", "持久化登录：重新打开后仍可读取")
        check(b.get("userInfo_https://a.test#2") == "{\"u\":\"v2\"}", "持久化登录：同域不同 # 后缀互相隔离")
        check(b.get("loginHeader_https://a.test#1") == "{\"Cookie\":\"k=v\"}", "持久化登录：loginHeader 一并保留")

        b.remove("userInfo_https://a.test#1")
        let c = PersistentLoginBackingStore(fileURL: file)
        check(c.get("userInfo_https://a.test#1") == nil && c.get("userInfo_https://a.test#2") != nil,
              "持久化登录：删除后重开不再出现，其余保留")
        c.remove("not-exist")

        // 文件损坏：视为空，且之后仍可写入
        try? Data("not json".utf8).write(to: file)
        let d = PersistentLoginBackingStore(fileURL: file)
        check(d.get("userInfo_https://a.test#2") == nil, "持久化登录：文件损坏视为空")
        d.set("k", "v")
        check(PersistentLoginBackingStore(fileURL: file).get("k") == "v", "持久化登录：损坏后可重新写入")

        // 与 SourceLoginStore 联动：getLoginInfoMap 回存后，重启仍优先返回已保存内容
        let f2 = dir.appendingPathComponent("store2.json")
        let s1 = SourceLoginStore(backing: PersistentLoginBackingStore(fileURL: f2),
                                  cookieReplacer: { _, _ in }, cookieRemover: { _ in })
        _ = s1.putLoginInfo("https://b.test", "{\"user\":\"u\",\"pwd\":\"p\"}")
        let s2 = SourceLoginStore(backing: PersistentLoginBackingStore(fileURL: f2),
                                  cookieReplacer: { _, _ in }, cookieRemover: { _ in })
        let m = s2.getLoginInfoMap("https://b.test", loginUiJSON: "[{\"name\":\"other\",\"type\":\"text\"}]")
        check(m["user"] == "u" && m["pwd"] == "p" && m["other"] == nil, "持久化登录：重启后已保存信息优先于 loginUi")
    }
}
