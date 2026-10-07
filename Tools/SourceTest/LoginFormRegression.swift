import Foundation

/// 登录表单：loginUi 解析、字段顺序/类型、已保存值优先、loginUrl 分类、脚本执行与 toast。离线。
enum LoginFormRegression {
    private static func src(_ extra: [String: Any]) throws -> BookSource {
        var o: [String: Any] = ["bookSourceUrl": "https://login-form.invalid", "bookSourceName": "form"]
        for (k, v) in extra { o[k] = v }
        return try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: o))
    }

    static func run(_ check: (Bool, String) -> Void) throws {
        let ui = "[{name:'账号',type:'text',default:'u0'},{name:'密码',type:'password'},{name:'登录',type:'button',action:'go()'},{name:'官网',type:'button',action:'https://a.invalid/'},]"
        let f = SourceLoginForm.parseFields(ui)
        check(f.map(\.name) == ["账号", "密码", "登录", "官网"], "登录表单：字段保持原顺序（宽松 JSON）")
        check(f.map(\.kind) == [.text, .password, .button, .button], "登录表单：type 映射")
        check(f[0].defaultValue == "u0" && f[2].action == "go()", "登录表单：default 与 action")
        check(SourceLoginForm.parseFields("").isEmpty && SourceLoginForm.parseFields("not json").isEmpty
              && SourceLoginForm.parseFields("{\"a\":1}").isEmpty && SourceLoginForm.parseFields(nil).isEmpty, "登录表单：非法或空输入得到空表单")
        check(SourceLoginForm.parseFields("[{type:'text'},{name:'x'}]").map(\.name) == ["x"], "登录表单：缺 name 的项被忽略")

        let vals = SourceLoginForm.initialValues(fields: f, saved: ["账号": "saved"])
        check(vals["账号"] == "saved" && vals["密码"] == "" && vals["登录"] == nil, "登录表单：已保存值优先于 default，按钮不取值")
        check(SourceLoginForm.encode(["b": "2", "a": "1"]) == "{\"a\":\"1\",\"b\":\"2\"}", "登录表单：保存 JSON 键有序")

        // <js> 形式的 loginUi 需要先求值
        let jsUi = "<js>JSON.stringify([{name:'检查',type:'button',action:'check()'}])</js>"
        let resolved = SourceLoginForm.resolveUiText(jsUi) { JSEngine.shared.evalString($0) }
        check(SourceLoginForm.parseFields(resolved).map(\.name) == ["检查"], "登录表单：<js> 形式的 loginUi 先求值再解析")
        check(SourceLoginForm.resolveUiText("[{name:'a'}]") { _ in nil } == "[{name:'a'}]", "登录表单：普通文本原样返回")

        // loginUrl 分类
        check(SourceLoginForm.loginScript("function login(){}") != nil, "loginUrl：函数库被识别为脚本")
        check(SourceLoginForm.loginScript("https://a.invalid/login") == nil && SourceLoginForm.loginScript("/") == nil, "loginUrl：网址和路径不是脚本")
        let web = try src(["loginUrl": "https://a.invalid/login"])
        let rel = try src(["loginUrl": "/user/login"])
        let none = try src([:])
        let uiOnly = try src(["loginUi": "[{name:'a'}]"])
        check(SourceLoginForm.loginPageURL(web) == "https://a.invalid/login", "loginUrl：绝对网址作为网页登录")
        check(SourceLoginForm.loginPageURL(rel) == "https://login-form.invalid/user/login", "loginUrl：相对路径按书源地址补全")
        check(SourceLoginForm.hasLogin(web) && SourceLoginForm.hasLogin(uiOnly) && !SourceLoginForm.hasLogin(none), "登录入口显示条件")

        // 脚本执行：toast 出口 + 读取表单保存的值 + 错误返回
        let s = try src(["bookSourceUrl": "https://login-run-\(UUID().uuidString.lowercased()).invalid"])
        var toasts: [String] = []
        ToastCenter.setHandler { toasts.append($0) }
        defer { ToastCenter.setHandler(nil) }
        let lib = "function hello(){java.toast('hi-'+source.getLoginInfoMap().user);return 'done';}function boom(){throw new Error('bad');}"
        JSEngine.loginStore.putLoginInfo(s.bookSourceUrl, SourceLoginForm.encode(["user": "u1"]))
        defer { JSEngine.loginStore.removeLoginInfo(s.bookSourceUrl) }
        if case .success(let r) = JSEngine.shared.runLoginScript(source: s, library: lib, call: "hello()") {
            check(r == "done" && toasts == ["hi-u1"], "登录脚本：执行函数、toast 出口、读到表单保存的值")
        } else { check(false, "登录脚本：执行函数") }
        if case .failure(let e) = JSEngine.shared.runLoginScript(source: s, library: lib, call: "boom()") {
            check(e.message.contains("bad"), "登录脚本：异常以 failure 返回")
        } else { check(false, "登录脚本：异常应返回 failure") }
        var opened: [String] = []
        ToastCenter.setBrowserHandler { u, _ in opened.append(u) }
        defer { ToastCenter.setBrowserHandler(nil) }
        _ = JSEngine.shared.runLoginScript(source: s, library: "function o(){java.startBrowser('https://b.invalid/','t');}", call: "o()")
        check(opened == ["https://b.invalid/"], "登录脚本：java.startBrowser 通过出口打开网址")
    }
}
