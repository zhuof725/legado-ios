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
