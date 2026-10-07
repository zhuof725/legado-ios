import Foundation

/// 柒默中文（起点 App 接口移植）书源：不联网，验证 jsLib 能加载、签名函数能在引擎里算出结果，
/// 搜索/目录/正文/详情规则能解码，以及段评相关函数存在。
enum QimoSourceRegression {
    static func run(_ check: (Bool, String) -> Void) throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools/SourceTest/Fixtures")
        let data = try Data(contentsOf: dir.appendingPathComponent("qimo-source.json"))
        let source = try JSONDecoder().decode(BookSource.self, from: data)
        check(source.bookSourceName == "柒默中文" && !(source.jsLib ?? "").isEmpty, "柒默：书源与 jsLib 可解码")
        check(source.ruleToc?.chapterList?.contains("transformChapters") == true
              && source.ruleContent?.content?.contains("qidianggetComments") == true, "柒默：目录与正文规则已读入")

        let ctx = RuleContext(source: source)
        func js(_ script: String) -> String { JSEngine.shared.evalString(script, jsLib: source.jsLib, context: ctx) ?? "<nil>" }

        check(js("typeof signSearch+'|'+typeof signToc+'|'+typeof qidianggetComments+'|'+typeof qidianggetCommentsIOS+'|'+typeof hqbl")
              == "function|function|function|function|function", "柒默：jsLib 里的签名与段评函数都已定义")

        // 签名函数在 this = 全局对象时可直接调用；搜索请求里 {{signSearch(...)}} 就是这么用的。
        let qdsign = js("signSearch('QDSign','斗罗',1)")
        check(!qdsign.isEmpty && qdsign != "<nil>" && qdsign.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil,
              "柒默：signSearch(QDSign) 产出 base64 签名")
        let info = js("signSearch('QDInfo','斗罗',1)")
        check(!info.isEmpty && info != "<nil>" && info.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil,
              "柒默：signSearch(QDInfo) 产出 base64")
        check(Int(js("signSearch('tstamp','斗罗',1)")) != nil, "柒默：signSearch(tstamp) 是时间戳")
        check(js("signSearch('UA','斗罗',1)").contains("Mozilla") || js("signSearch('UA','斗罗',1)").count > 8, "柒默：signSearch(UA) 有值")
        check(js("signToc('QDSign','1043')").range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil, "柒默：signToc 可用")

        // 搜索 URL 模板：{{signSearch(...)}} 展开后应得到带 QDSign 头的请求
        let req = AnalyzeUrl(rawUrl: source.searchUrl ?? "", key: "斗罗", page: 1, baseUrl: source.bookSourceUrl,
                             sourceHeader: source.header, context: RuleContext(source: source), jsLib: source.jsLib)
        check(req.method == "POST" && (req.body ?? "").contains("keyword=斗罗"), "柒默：搜索请求为 POST 且带关键词")
        check((req.headers["QDSign"] ?? "").isEmpty == false && (req.headers["QDInfo"] ?? "").isEmpty == false, "柒默：搜索请求头带 QDSign/QDInfo")

        // 书源配置：评论开关的存取
        _ = JSEngine.shared.evalString("source.setVariable(JSON.stringify({'评论':'已关'}))", context: ctx)
        check(js("hqbl('评论')") == "已关", "柒默：评论开关从书源变量读取")
        _ = JSEngine.shared.evalString("source.setVariable('')", context: ctx)
    }
}
