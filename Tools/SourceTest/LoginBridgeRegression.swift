import Foundation

/// Offline fixtures with synthetic values only. Registered in Regression.swift.
enum LoginBridgeRegression {
    static func run(_ check: (Bool, String) -> Void) {
        // Lenient loginUi shapes seen in real sources: bare keys, single quotes,
        // comments, trailing commas, bare values.
        let lenientUi = """
        [
          // comment
          {name: "account", type: "text"},
          {'name': 'password', 'type': 'password', 'default': 'secret-default',},
          {name: "go", type: "button", action: "login()", style: {layout_flexBasisPercent: 1}},
          /* block */ {"name": "n", "type": "text", "default": 5},
        ]
        """
        let map = SourceLoginStore(
            backing: InMemorySourceLoginBackingStore(),
            cookieReplacer: { _, _ in }, cookieRemover: { _ in }
        ).getLoginInfoMap("https://lenient.invalid", loginUiJSON: lenientUi)
        check(map == ["account": "", "password": "secret-default", "n": "5"],
              "lenient loginUi parses bare keys, single quotes, comments, trailing commas")

        let base = "https://login-bridge.invalid/" + UUID().uuidString
        func make(_ suffix: String, ui: String?) throws -> BookSource {
            var json: [String: Any] = ["bookSourceUrl": base + suffix, "bookSourceName": "login bridge"]
            if let ui = ui { json["loginUi"] = ui }
            return try JSONDecoder().decode(BookSource.self,
                from: try JSONSerialization.data(withJSONObject: json))
        }
        do {
            let a = try make("#a", ui: lenientUi)
            let b = try make("#b", ui: nil)
            check(a.loginUi == lenientUi, "BookSource decodes loginUi")
            let ca = RuleContext(source: a), cb = RuleContext(source: b)
            let engine = JSEngine.shared
            func js(_ script: String, _ c: RuleContext) -> String {
                engine.evalString(script, result: "", baseUrl: base, context: c) ?? "<nil>"
            }
            check(js("JSON.stringify(source.getLoginInfoMap())", ca)
                  == #"{"account":"","n":"5","password":"secret-default"}"#,
                  "source.getLoginInfoMap falls back to loginUi defaults")
            check(js("String(source.putLoginInfo('{\"account\":\"u1\"}'))", ca) == "true",
                  "source.putLoginInfo stores")
            check(js("source.getLoginInfoMap().account", ca) == "u1", "stored login info is read back")
            check(js("source.getLoginInfoMap().get('account')", ca) == "u1", "getLoginInfoMap().get(key) 读取已保存值（Kotlin Map 写法）")
            check(js("String(source.getLoginInfoMap().get('nope'))", ca) == "null", "getLoginInfoMap().get 缺键返回 null")
            check(js("var m=source.getLoginInfoMap(); [m.containsKey('account'), m.containsKey('nope'), m.getOrDefault('nope','d'), Object.keys(m).join(',')].join('|')", ca) == "true|false|d|account", "Map 方法不污染 Object.keys")
            check(js("String(source.getLoginInfoMap().account)", cb) == "undefined",
                  "login info is isolated per source key")
            js("source.putLoginHeader('{\"Cookie\":\"sid=abc\",\"X-T\":\"1\"}')", ca)
            check(js("source.getLoginHeaderMap()['X-T']", ca) == "1", "login header map round trip")
            check(js("String(source.getLoginHeaderMap())", cb) == "null", "login header isolated per source")
            js("source.removeLoginHeader()", ca)
            check(js("String(source.getLoginHeader())", ca) == "null", "removeLoginHeader clears header")
            js("source.removeLoginInfo()", ca)
            check(js("source.getLoginInfoMap().account", ca) == "", "removeLoginInfo falls back to defaults again")
        } catch {
            check(false, "login bridge fixture setup failed")
        }
    }
}
