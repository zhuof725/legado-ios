import Foundation

/// 本地书导入：TXT（编码、章节识别、兜底切段）与 EPUB（容器、目录标题、封面、实体、压缩方式）。离线，用仓库内夹具。
enum LocalBookRegression {
    static func run(_ check: (Bool, String) -> Void) throws {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tools/SourceTest/Fixtures")
        func load(_ n: String) throws -> Data { try Data(contentsOf: dir.appendingPathComponent(n)) }

        // 章节标题识别
        for t in ["第一章 出发", "第12章", "第一百二十回 结局", "Chapter 3 Start", "序章", "番外 小故事", "第 5 节"] {
            check(LocalBook.isChapterTitle(t), "TXT 标题识别：\(t)")
        }
        for t in ["他说第一章已经写完了，然后继续写下去，一直写到很晚才睡觉，这一整行很长很长很长很长很长很长。", "", "普通的一句话"] {
            check(!LocalBook.isChapterTitle(t), "TXT 非标题：\(t.prefix(8))")
        }

        // GBK 编码 + 文件名里的书名作者
        let gbk = try LocalBook.parseTXT(try load("sample-gbk.txt"), fileName: "《测试书》作者：张三.txt")
        check(gbk.title == "测试书" && gbk.author == "张三", "TXT：文件名解析书名与作者")
        check(gbk.chapters.map(\.title) == ["序章", "第一章 出发", "第二章 到达"], "TXT：GBK 解码并按标题切章")
        check(gbk.chapters[1].text == "他出发了。", "TXT：章节正文不含标题行")
        // 开头只有书名/作者行时不单独成「前言」，且能补全作者
        let headOnly = try LocalBook.parseTXT(try load("sample-gbk.txt"), fileName: "无信息.txt")
        check(headOnly.author == "张三" && headOnly.chapters.first?.title == "序章", "TXT：开头的书名作者行不成章，并补全作者")
        // 较长的前言保留为一章
        let longPre = String(repeating: "这是一段较长的前言文字。", count: 12) + "\n第一章 开始\n正文\n第二章 继续\n更多"
        let keep = try LocalBook.parseTXT(Data(longPre.utf8), fileName: "书.txt")
        check(keep.chapters.first?.title == "前言" && keep.chapters.count == 3, "TXT：较长的前言保留为一章")

        // 无章节、带 BOM：按字数切段
        let plain = try LocalBook.parseTXT(try load("sample-plain.txt"), fileName: "随笔.txt")
        check(plain.chapters.count > 1 && plain.chapters.allSatisfy { $0.title.hasPrefix("第 ") }, "TXT：无章节标题时按字数切段")
        check(plain.chapters.first?.text.hasPrefix("一些") == true, "TXT：UTF-8 BOM 被去掉")
        check({ do { _ = try LocalBook.parseTXT(Data("   \n".utf8), fileName: "空.txt"); return false } catch { return (error as? LocalBookError) == .empty } }(), "TXT：空文件报 empty")

        // EPUB
        let epub = try LocalBook.parseEPUB(try load("sample.epub"), fileName: "x.epub")
        check(epub.title == "测试之书" && epub.author == "某作者", "EPUB：书名与作者")
        check(epub.chapters.map(\.title) == ["第一章 开始", "第二章 继续"], "EPUB：目录标题取自 nav，含锚点的链接也能对上")
        check(epub.chapters[0].text.contains("这是第一段。& 测试中文。") && epub.chapters[0].text.contains("这是第二段。"), "EPUB：Deflate 章节、实体与数字实体还原")
        check(epub.chapters[1].text == "第二章内容。", "EPUB：Stored 章节、script 被去掉")
        check(epub.coverData?.starts(with: [0xFF, 0xD8]) == true, "EPUB：读出封面图片")
        check({ do { _ = try LocalBook.parseEPUB(Data("not a zip at all, definitely".utf8), fileName: "bad.epub"); return false } catch { return (error as? LocalBookError) == .unreadable } }(), "EPUB：不是 ZIP 报 unreadable")

        // 工具函数
        check(LocalBook.normalize("OEBPS/text/../img/./a.jpg") == "OEBPS/img/a.jpg", "路径规范化处理 .. 与 .")
        check(LocalBook.htmlToText("<p>甲</p><p>乙&nbsp;丙</p>") == "甲\n乙 丙", "HTML 转文本")
        check(LocalBook.unescape("&#x4e2d;&#25991;") == "中文", "数字实体（十六进制与十进制）")
    }
}
