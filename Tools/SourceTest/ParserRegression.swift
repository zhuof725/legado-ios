import Foundation

/// Hook into the existing runner with ParserRegression.run(check).
/// No network is needed; JS boundary and template cases use the local JSEngine.
enum ParserRegression {
    static func run(_ check: (Bool, String) -> Void) {
        func strings(_ root: Any, _ path: String) -> [String] {
            JsonPath.query(root, path).map { AnalyzeRule.asString($0) }
        }

        let rows: [[String: Any]] = [
            ["id": "a", "n": 1, "active": true, "name": "x@y&&z||q%%p"],
            ["id": "b", "n": 2, "active": false, "name": "ordinary"],
            ["id": "c", "n": 3, "active": true, "name": "ordinary"]
        ]
        let root: [String: Any] = ["rows": rows, "limit": 2]
        let filter = #"$.rows[?(@.active == true && (@.n < 2 || @.n >= 3))].id"#
        check(strings(root, filter) == ["a", "c"], "JSONPath 过滤器内部逻辑符及括号")
        check(strings(root, #"$.rows[?(@.name == 'x@y&&z||q%%p')].id"#) == ["a"], "JSONPath 引号内组合符和 @ 保持原样")
        check(strings(root, "$.rows[?(@.n >= $.limit)].id") == ["b", "c"], "过滤器根节点引用")
        check(strings(root, "$.rows[?(@.active == 1)].id").isEmpty, "布尔值不与数字一混同")
        check(strings(root, "$.rows[?(@.id in ['a','c'])].id") == ["a", "c"], "过滤器联合字面量")
        check(strings(root, "$.rows[?(@.missing)]").isEmpty, "缺失字段存在性判断")
        check(strings(root, "$.rows[?(@.n unknown 2)]").isEmpty, "未知过滤器不得匹配全部")
        check(strings(root, "$.rows[?(@.n unknown 2 || @.n == 1)]").isEmpty, "未知过滤器分支整体失败关闭")
        check(strings(root, "$.rows[?(@.n ==)]").isEmpty, "不完整比较不得匹配全部")

        let numbers = [0, 1, 2, 3, 4]
        check(strings(numbers, "$[1:4]") == ["1", "2", "3"], "JSONPath 切片右端不包含")
        check(strings(numbers, "$[:3]") == ["0", "1", "2"], "JSONPath 省略起点")
        check(strings(numbers, "$[-3:]") == ["2", "3", "4"], "JSONPath 负数起点")
        check(strings(numbers, "$[::2]") == ["0", "2", "4"], "JSONPath 切片步长")
        check(strings(numbers, "$[::-1]") == ["4", "3", "2", "1", "0"], "JSONPath 反向切片")
        check(strings(numbers, "$[0:4:0]").isEmpty, "零步长失败关闭")
        check(strings(numbers, "$[3,0,-1]") == ["3", "0", "4"], "联合索引保留顺序")
        check(strings(numbers, "$.[*]") == ["0", "1", "2", "3", "4"], "原有根数组 $.[*] 不退化")
        check(strings(["chapters": numbers], "$.chapters.[*]") == ["0", "1", "2", "3", "4"], "原有字段数组 .[*] 不退化")
        check(strings(numbers, "$[*]").count == 5, "原有标准通配不退化")
        check(strings(["a": 1, "b": 2], "$['b','a']") == ["2", "1"], "联合字段保留顺序")
        check(strings(["x@y": 7], "$['x@y']") == ["7"], "引号字段中的 @")
        let nested: [String: Any] = ["a": ["v": 1], "b": [2, 3]]
        let descendants = JsonPath.query(nested, "$..*")
        check(descendants.count == 5, "递归通配遍历容器和叶子且不重复")
        check(descendants.compactMap { $0 as? Int }.sorted() == [1, 2, 3], "递归通配包含所有叶子")
        check(strings(["v": 0, "child": ["v": 1]], "$..v").sorted() == ["0", "1"], "递归字段查询")
        check(JsonPath.isSimpleKeyRule("body.books[0].name"), "简写字段调用兼容")
        check(!JsonPath.isSimpleKeyRule("@css:a[href]"), "CSS 不被识别为简写字段")

        let protected = RuleScanner.split(filter + "&&$.rows[0].id||$.rows[1].id", by: ["&&", "||", "%%"])
        check(protected.valid && protected.separator == "&&" && protected.parts.count == 2, "组合类型遵循首个顶层操作符")
        check(protected.parts.first == filter, "组合扫描不切开过滤器")
        let at = RuleScanner.split(#"a[data-mail='x@y']@href"#, by: ["@"])
        check(at.valid && at.parts == [#"a[data-mail='x@y']"#, "href"], "属性扫描保护引号内 @")
        check(!RuleScanner.split("a[broken&&b", by: ["&&"]).valid, "不平衡扫描返回失败")

        // Completion of this loop is also a regression guard against hangs.
        let malformed = ["", "$[", "$..", "$.", "$[]", "$[?(@.n == 1]", "$[1:2:0]", "$[1,]", "$['unterminated]", "$[0]]", "$...a", "$[999999999999999999999999999999]"]
        for path in malformed {
            check(JsonPath.query(root, path).isEmpty, "畸形 JSONPath 终止并失败关闭: \(path)")
        }
        let tooDeep = "$[?(" + String(repeating: "(", count: 100) + "@.n == 1" + String(repeating: ")", count: 100) + ")]"
        check(JsonPath.query(rows, tooDeep).isEmpty, "谓词深度上限终止")
        check(strings(numbers, "$[::\(Int.max)]") == ["0"], "极大步长安全终止")
        check(strings(numbers, "$[::\(Int.min)]") == ["4"], "极小步长安全终止")

        check(AnalyzeRule.pickIndexes(numbers, "0:3") == [0, 1, 2, 3], "CSS 切片继续包含右端")
        check(AnalyzeRule.pickIndexes(numbers, "-1:0") == [4, 3, 2, 1, 0], "CSS 反向切片保持原顺序")
        check(AnalyzeRule.pickIndexes(numbers, "0:\(Int.max)") == numbers, "CSS 极大范围仅遍历有效索引")
        check(AnalyzeRule.pickIndexes(numbers, "0:4:\(Int.min)") == numbers, "CSS 最小整数步长安全回退为一且不触发溢出")
        check(AnalyzeRule.pickIndexes(numbers, "0:4:1:2").isEmpty, "CSS 多余切片字段失败关闭")
        check(AnalyzeRule.pickIndexes(numbers, "0:invalid").isEmpty, "CSS 畸形切片边界失败关闭")

        let json = AnalyzeRule(content: root, baseUrl: "https://example.invalid/")
        check(json.getString(filter) == "a\nc", "字符串规则集成过滤器扫描")
        check(json.getElements(filter).map { AnalyzeRule.asString($0) } == ["a", "c"], "元素规则集成过滤器扫描")
        check(json.getString("@@rows") == "", "@@ 强制默认模式不回落 JSON")
        check(json.getElements("@@rows").isEmpty, "元素 @@ 强制默认模式")
        check(json.getString("$.rows[0].id&&$.rows[1].id||$.missing") == "a\nb", "字符串混合组合首操作符决定类型")

        let html = "<ul><li>A</li><li>B</li><li>C</li></ul><a data-mail='x@y' href='/same'>One</a><a href='/same'>Two</a><a href='/other'>Three</a><div id='box'><b>Keep</b><script>bad()</script><style>b{}</style></div>"
        let context = RuleContext()
        let doc = AnalyzeRule(content: html, baseUrl: "https://example.invalid/", context: context)
        check(doc.getString(#"a[data-mail='x@y']@href"#) == "/same", "默认选择器引号内 @ 不误切")
        check(doc.getString(#"@css:a[data-mail='x@y']@href"#) == "/same", "CSS 选择器引号内 @ 不误切")
        check(doc.getString("tag.a@href") == "/same\n/other", "属性去重保留首次出现顺序")
        check(doc.getString("tag.li[0:1]@text") == "A\nB", "CSS 索引切片仍包含右端")
        check(doc.getString("tag.li[-1:0]@text") == "C\nB\nA", "CSS 反向索引不退化")
        check(doc.getString("li.1@text") == "B", "CSS 尾部索引不退化")
        check(doc.getString("tag.li[!1]@text") == "A\nC", "CSS 排除索引不退化")
        check(doc.getString("tag.li[2,0,2,-1]@text") == "C\nA", "CSS 联合索引按首次出现顺序去重")
        check(AnalyzeRule.pickIndexes([0, 1, 2, 3, 4], "-99:4:2") == [0, 2, 4], "CSS 越界起点先截断再计算步长")
        check(AnalyzeRule.pickIndexes([0, 1, 2, 3, 4], "99:0:2") == [4, 2, 0], "CSS 反向区间先截断起点")
        check(AnalyzeRule.pickIndexes([0, 1, 2, 3, 4], "0:4:-2") == [0, 3], "CSS 负步长按列表长度归一化")
        check(AnalyzeRule.pickIndexes([0, 1, 2, 3, 4], "0:4:0") == [0], "CSS 零步长遵循 Kotlin 长度归一化")
        check(AnalyzeRule.pickIndexes([0, 1, 2], "99:100").isEmpty, "CSS 同侧越界区间为空")
        check(AnalyzeRule.pickIndexes([0, 1, 2], "0:2:\(Int.min)") == [0, 1, 2], "CSS 极小负步长安全归一化")
        check(AnalyzeRule.pickIndexes([0, 1, 2], "0:2:\(Int.max)") == [0], "CSS 极大步长仅保留起点")
        let elements = doc.getElements(#"@put:{"saved":"tag.li.0@text"}tag.li"#)
        check(elements.count == 3 && context.get("saved") == "A", "元素规则执行 @put")
        check(doc.getString("@get:{saved}") == "A", "直接 @get:{key} 取值")
        check(doc.getString("prefix-@get:{saved}-suffix") == "prefix-A-suffix", "@get 插值作为文本输出")
        check(doc.getString("{{@get:{saved}}}") == "A", "模板嵌套变量括号")
        let outer = doc.getString("id.box@html")
        check(outer.contains("<div") && outer.contains("<b>Keep</b>") && !outer.contains("<script") && !outer.contains("<style"), "@html 输出去除脚本样式的 outerHtml")

        // Match Kotlin's JS_PATTERN without attempting to lex JavaScript.
        check(doc.getString(#"<js>/'/.test("'") ? 'before' : 'wrong';</js>##^[\s\S]*before[\s\S]*$##after"#) == "after", "JS 正则单引号不吞掉闭合标签后的替换规则")
        check(doc.getString(#"<JS>/}/.test('}') ? 'before' : 'wrong';</Js>##^[\s\S]*before[\s\S]*$##after"#) == "after", "JS 正则右括号及大小写标签保留后续替换")
        check(doc.getString(#"<js>/* unmatched ( [ { ' */ 'before';</js>##^[\s\S]*before[\s\S]*$##after"#) == "after", "JS 注释中的不平衡符号不影响后续替换")

        let templateContext = RuleContext()
        let templateLibrary = "function parserTemplateValue() { java.put('parserTemplateCalls', String(Number(java.get('parserTemplateCalls') || '0') + 1)); return 'library-value'; }"
        let templateDoc = AnalyzeRule(content: "<ul><li>A</li><li>B</li></ul>",
                                      baseUrl: "https://example.invalid/", jsLib: templateLibrary,
                                      context: templateContext)
        check(templateDoc.getString(#"@js:'{{parserTemplateValue()}}'"#) == "library-value", "内嵌 JS 模板可调用 jsLib 库函数")
        check(templateContext.get("parserTemplateCalls") == "1", "普通模板表达式只求值一次且共享变量上下文")
        let templateNodes = templateDoc.getElements("tag.li")
        check(templateNodes.count == 2, "模板当前节点回归取得两个原生元素")
        if templateNodes.count == 2 {
            check(templateDoc.getString(#"@js:'{{java.getString("ownText")}}'"#, from: templateNodes[1]) == "B", "内嵌模板 java.getString 使用当前原生节点而非整篇文档")
        }
    }
}
