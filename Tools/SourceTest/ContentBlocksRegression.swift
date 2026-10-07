import Foundation

/// 正文块解析：段尾 <comment>、图片块、点击网址、普通文本不变。纯函数，离线。
enum ContentBlocksRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let plain = ContentBlocks.parse("第一段<br>第二段\n\n  第三段  ")
        check(plain == [.paragraph(text: "第一段", commentCount: 0, commentURL: nil),
                        .paragraph(text: "第二段", commentCount: 0, commentURL: nil),
                        .paragraph(text: "第三段", commentCount: 0, commentURL: nil)], "正文块：普通文本逐行成段，去空行")

        let url = "https://qdgo.qimo.host/reviews?bookId=1&chapterId=2&paragraphId=3"
        let raw = "<div rs-native>第一段<comment count=\"7\" onClick=\"java.startBrowser('\(url)')\"/></div>\n<div rs-native>第二段</div>"
        let b = ContentBlocks.parse(raw)
        check(b.count == 2, "正文块：div 包裹的段落数")
        check(b.first == .paragraph(text: "第一段", commentCount: 7, commentURL: url), "正文块：段尾评论数与链接")
        check(b.last == .paragraph(text: "第二段", commentCount: 0, commentURL: nil), "正文块：无评论的段落不带气泡")

        let img = "<img src=\"data:image/svg+xml;base64,PHN2Zy8+\" onClick=\"java.startBrowser('\(url)&x=0')\"/>"
        let withImg = ContentBlocks.parse("第一段\n" + img)
        check(withImg.last == .image(src: "data:image/svg+xml;base64,PHN2Zy8+", clickURL: url + "&x=0"), "正文块：iOS 版图片块的点击网址")
        let android = "第一段<img src=\"data:image/svg+xml;base64,PHN2Zy8+,{\"style\":\"FULL\",\"type\":\"god\",\"click\":\"java.startBrowser('\(url)')\"}\">"
        let ab = ContentBlocks.parse(android)
        check(ab.count == 2, "正文块：Android 版图片与段落分块")
        if case .image(let s, let c) = ab.last! { check(s == "data:image/svg+xml;base64,PHN2Zy8+", "正文块：Android 版 src 去掉选项") ; _ = c } else { check(false, "正文块：Android 版应得到图片块") }

        let mixed = ContentBlocks.parse("甲<comment count=\"3\"/>乙")
        check(mixed.count == 1, "正文块：同一行里评论标签前后的文字合并为一段")
        check(ContentBlocks.parse("<comment count=\"2\"/>").isEmpty, "正文块：没有文字的孤立评论标签被忽略")
        check(ContentBlocks.urlInCall("java.startBrowser('https://a.invalid/x','t')") == "https://a.invalid/x", "正文块：从 startBrowser 调用取网址")
        check(ContentBlocks.urlInCall("alert(1)") == nil, "正文块：非 startBrowser 调用不取网址")

        let blocks = ContentBlocks.parse("甲<comment count=\"5\"/>\n乙")
        check(ContentBlocks.plainText(blocks) == "\u{3000}\u{3000}甲\n\u{3000}\u{3000}乙", "正文块：plainText 与旧版缩进一致且丢弃评论标记")
    }
}

enum CommentCardRegression {
    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    static func run(_ check: (Bool, String) -> Void) {
        let hot = "<svg width=\"1000\" height=\"140\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"100%\" height=\"100%\" fill=\"rgba(210,210,210,0.5)\" rx=\"70\"/><text x=\"102\" y=\"84\" font-size=\"32\" fill=\"#FFF\" text-anchor=\"middle\">热评</text><text x=\"196\" y=\"84\" font-size=\"40\" fill=\"#000\">暴露个毛啊，仔细一看辈分，就是在描述…</text></svg>"
        let url = "https://qdgo.qimo.host/reviews?bookId=1&chapterId=2&paragraphId=3"
        let raw = "甲段<comment count=\"6\"/>\n<img src=\"data:image/svg+xml;base64,\(b64(hot))\" onClick=\"java.startBrowser('\(url)')\"/>\n乙段"
        let blocks = ContentBlocks.parse(raw)
        check(blocks.count == 3, "热评卡片：段落、热评、段落共 3 块")
        check(blocks[1] == .hotComment(label: "热评", text: "暴露个毛啊，仔细一看辈分，就是在描述…", clickURL: url), "热评卡片：SVG 转成原生块并保留点击网址")

        let chapter = "<svg width=\"1000\" height=\"1\"><text x=\"40\" y=\"42\">本章说</text><text x=\"960\" y=\"42\" text-anchor=\"end\">33 条评论 〉</text><text x=\"40\" y=\"100\">某用户</text></svg>"
        let cb = ContentBlocks.parse("<img src=\"data:image/svg+xml;base64,\(b64(chapter))\" onClick=\"java.startBrowser('\(url)')\"/>")
        if case .chapterComments(let t, let c, _, let u)? = cb.first {
            check(t == "本章说" && c == "33 条评论 〉" && u == url, "章评卡片：标题、计数、点击网址")
        } else { check(false, "章评卡片：应识别为 chapterComments") }

        let other = "<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"5\"/></svg>"
        let ob = ContentBlocks.parse("<img src=\"data:image/svg+xml;base64,\(b64(other))\"/>")
        check({ if case .image? = ob.first { return true }; return false }(), "热评卡片：不是评论的 SVG 仍按图片显示")
        check(ContentBlocks.svgTexts("<svg><text>a &amp; b</text></svg>") == ["a & b"], "热评卡片：XML 实体被还原")
        check(ContentBlocks.svgText("https://a.invalid/x.png") == nil, "热评卡片：非 data 地址不当作 SVG")
        // 老缓存里没有评论标记的纯文本仍按旧路径显示
        check(!ContentBlocks.parse("纯文本").contains { if case .paragraph(_, let c, _) = $0 { return c > 0 }; return false }, "热评卡片：纯文本不产生评论块")
    }
}

enum InlineBubbleRegression {
    private static func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    static func run(_ check: (Bool, String) -> Void) {
        // 番茄书源：气泡是 style=text 的 SVG，点击是书源函数调用而不是网址。
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"126\" height=\"146\"><text x=\"38\" y=\"97\">12</text></svg>"
        let src = "data:image/svg+xml;base64,\(b64(svg)),{\"style\":\"text\",\"type\":\"qd\",\"click\":\"showCmt('b1','c2','3','12')\"}"
        let raw = "他赶至窗户边上。<img src=\"\(src)\">\n下一段"
        let blocks = ContentBlocks.parse(raw)
        check(blocks.count == 2, "行内气泡：并入前一段，不单独成块")
        check(blocks.first == .paragraph(text: "他赶至窗户边上。", commentCount: 12, commentURL: "js:showCmt('b1','c2','3','12')"),
              "行内气泡：评论数取自图里的数字，点击保留为书源函数调用")
        check(ContentBlocks.srcOptions(src)["style"] == "text" && ContentBlocks.srcOptions(src)["type"] == "qd", "行内气泡：选项里的 style/type")
        check(ContentBlocks.clickFromOptions(["click": "showCmt('1')"]) == "js:showCmt('1')", "点击目标：函数调用以 js: 标记")
        check(ContentBlocks.clickFromOptions(["click": "java.startBrowser('https://a.invalid/x')"]) == "https://a.invalid/x", "点击目标：startBrowser 直接取网址")
        check(ContentBlocks.clickFromOptions([:]) == nil, "点击目标：没有 click 时为空")
        // 前面没有段落的孤立气泡丢弃，不崩溃
        check(ContentBlocks.parse("<img src=\"\(src)\">").isEmpty, "行内气泡：没有前文时丢弃")
        // style 不是 text 的图片仍是独立图片
        let full = "data:image/svg+xml;base64,\(b64("<svg xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"3\"/></svg>")),{\"style\":\"full\"}"
        check({ if case .image? = ContentBlocks.parse("x<img src=\"\(full)\">").last { return true }; return false }(), "整行图片：style=full 仍是独立图片块")

        // 书源脚本里 showBrowser/startBrowser 的网址可以被捕获
        let ctx = RuleContext()
        _ = ctx
        var got: [String] = []
        ToastCenter.pushBrowserCapture { got.append($0) }
        defer { ToastCenter.popBrowserCapture() }
        ToastCenter.openBrowser("https://c.invalid/viewer", "")
        check(got == ["https://c.invalid/viewer"], "评论点击：网址被捕获而不是弹系统浏览器")
    }
}
