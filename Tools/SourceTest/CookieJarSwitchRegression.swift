import Foundation

/// enabledCookieJar：模型默认值、解码、以及 AnalyzeUrl 是否继承开关。不发网络请求。
enum CookieJarSwitchRegression {
    private static func source(_ extra: [String: Any]) throws -> BookSource {
        var o: [String: Any] = ["bookSourceUrl": "https://jar.invalid", "bookSourceName": "jar"]
        for (k, v) in extra { o[k] = v }
        return try JSONDecoder().decode(BookSource.self, from: JSONSerialization.data(withJSONObject: o))
    }

    static func run(_ check: (Bool, String) -> Void) throws {
        let missing = try source([:])
        check(missing.enabledCookieJar == nil && missing.cookieJarEnabled, "enabledCookieJar 缺省视为开启")
        let on = try source(["enabledCookieJar": true])
        check(on.cookieJarEnabled, "enabledCookieJar=true 开启")
        let off = try source(["enabledCookieJar": false])
        check(!off.cookieJarEnabled, "enabledCookieJar=false 关闭")
        let bad = try source(["enabledCookieJar": "yes"])
        check(bad.cookieJarEnabled, "enabledCookieJar 类型异常时按默认开启")

        let withOff = AnalyzeUrl(rawUrl: "https://jar.invalid/a", baseUrl: off.bookSourceUrl, context: RuleContext(source: off))
        let withOn = AnalyzeUrl(rawUrl: "https://jar.invalid/a", baseUrl: on.bookSourceUrl, context: RuleContext(source: on))
        let noCtx = AnalyzeUrl(rawUrl: "https://jar.invalid/a")
        check(!withOff.cookieJarEnabled, "AnalyzeUrl 继承书源关闭开关")
        check(withOn.cookieJarEnabled && noCtx.cookieJarEnabled, "AnalyzeUrl 默认开启 Cookie")
    }
}
