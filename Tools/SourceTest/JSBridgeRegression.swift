import Foundation
import SwiftSoup

/// Offline fixtures only. Run on a host with Swift, JavaScriptCore and SwiftSoup.
/// This file deliberately does not register itself in the shared test runner.
enum JSBridgeRegression {
    static func run(_ check: (Bool, String) -> Void) {
        let original = "<main><h1>Original</h1><a href='/old'>Old</a></main>"
        let replacement = "<main><h1>Replacement</h1><a href='/new'>New</a><a href='/next'>Next</a></main>"
        let explicit = "<section><h1>Explicit</h1><a href='/explicit'>Other</a></section>"
        let baseURL = "https://example.invalid/books/index.html"
        let context = RuleContext()
        let library = "var bridgeLibraryValue = 'library';"
        let rule = AnalyzeRule(content: original, baseUrl: baseURL,
                               jsLib: library, context: context)
        let engine = JSEngine.shared

        func evaluate(_ script: String) -> Any? {
            engine.eval(script, result: original, baseUrl: baseURL,
                        vars: ["replacementHTML": replacement, "explicitHTML": explicit],
                        jsLib: library, rule: rule, ruleInput: rule.content,
                        context: context)
        }

        check(evaluate("""
            var before = java.getString('@css:h1@text');
            var beforeCount = java.getElements('@css:a').length;
            java.setContent(replacementHTML);
            [before, beforeCount, java.getString('@css:h1@text'),
             java.getElements('@css:a').length,
             java.getElement('@css:a').text(), result === replacementHTML].join('|');
            """) as? String == "Original|1|Replacement|2|New|true",
              "setContent switches both string and element queries and preserves result assignment")

        check(evaluate("""
            java.setContent(replacementHTML);
            [java.getString('@css:h1@text', explicitHTML),
             java.getString('@css:h1@text'),
             java.getElements('@css:a').length].join('|');
            """) as? String == "Explicit|Replacement|2",
              "explicit content is queried without replacing current content")

        check(evaluate("""
            [java.getString('@css:h1@text', ''),
             java.getString('@css:h1@text', null),
             java.getString('@css:h1@text', undefined),
             java.getString('@css:h1@text')].join('|');
            """) as? String == "|||Original",
              "only omitted content falls back; empty, null and undefined are explicit empty input")

        check(evaluate("""
            var parsed = Packages.org.jsoup.Jsoup.parse(explicitHTML);
            [parsed.select('h1').text(), parsed.select('a').size(),
             parsed.select('a').get(0).attr('href'),
             parsed.text().indexOf('<') === -1,
             org.jsoup === Packages.org.jsoup,
             org.jsoup.Jsoup.parse(replacementHTML).select('h1').text(),
             java.getString('@css:h1@text')].join('|');
            """) as? String == "Explicit|1|/explicit|true|true|Replacement|Original",
              "Jsoup parses supplied HTML, exposes org alias and does not query or replace original root")

        check(evaluate("""
            java.setContent(org.jsoup.Jsoup.parse(replacementHTML));
            [java.getString('@css:h1@text'),
             java.getString('@css:h1@text', org.jsoup.Jsoup.parse(explicitHTML)),
             java.getString('@css:h1@text')].join('|');
            """) as? String == "Replacement|Explicit|Replacement",
              "native document arguments support current and explicit content")

        check(evaluate("java.setContent(replacementHTML); java.getString('@css:h1@text')") as? String == "Replacement",
              "first evaluation observes its replacement")
        check(evaluate("java.getString('@css:h1@text')") as? String == "Original",
              "second evaluation on same engine and analyzer starts from original content")
        check(rule.getString("@css:h1@text") == "Original",
              "setContent does not mutate supplied analyzer root")

        check(evaluate("""
            java.put('bridgeRegressionValue', 'kept');
            java.setContent(replacementHTML);
            [baseUrl, bridgeLibraryValue, java.get('bridgeRegressionValue'),
             java.getString('@css:a@abs:href', explicitHTML)].join('|');
            """) as? String == "https://example.invalid/books/index.html|library|kept|https://example.invalid/explicit",
              "content switching retains base URL, library and RuleContext")
        check(context.get("bridgeRegressionValue") == "kept",
              "java.put continues writing the supplied RuleContext")

        check(engine.eval("boundAtLibraryLoad", result: original, baseUrl: baseURL,
                          vars: ["key": "fixture"],
                          jsLib: "var boundAtLibraryLoad = [java.getString('@css:h1@text'), baseUrl, key].join('|');",
                          rule: rule, context: context) as? String
              == "Original|https://example.invalid/books/index.html|fixture",
              "query and request bindings are installed before jsLib execution")

        check(engine.evalString("java.setContent('<h1>Standalone</h1>'); java.getString('@css:h1@text')",
                                result: original, baseUrl: baseURL) == "Standalone",
              "content bridge also works without an explicit AnalyzeRule")
        check(engine.evalString("java.getString('@css:h1@text')", result: original,
                                baseUrl: baseURL) == "Original",
              "standalone evaluations do not share content state")

        let returnedNode = evaluate("org.jsoup.Jsoup.parse(explicitHTML).select('section').get(0)")
        check(returnedNode is Element, "JS node return is unwrapped to a native SwiftSoup Element")
        check(returnedNode.map { rule.getString("@css:h1@text", from: $0) } == "Explicit",
              "returned native node remains queryable by AnalyzeRule")

        let returnedList = evaluate("org.jsoup.Jsoup.parse(replacementHTML).select('a')") as? [Any]
        check(returnedList?.count == 2 && returnedList?.allSatisfy { $0 is Element } == true,
              "JS node-list return is unwrapped to native elements")
        check(returnedList?.first.map { rule.getString("text", from: $0) } == "New",
              "native list entry remains queryable by AnalyzeRule")

        let returnedArray = evaluate("org.jsoup.Jsoup.parse(replacementHTML).select('a').toArray()") as? [Any]
        check(returnedArray?.count == 2 && returnedArray?.allSatisfy { $0 is Element } == true,
              "JS array return recursively unwraps node wrappers")

        let pipeline = rule.getElements("@js:org.jsoup.Jsoup.parse('<article><h1>Pipeline</h1></article>').select('article')")
        check(pipeline.count == 1 && pipeline.first is Element,
              "AnalyzeRule JS pipeline receives native elements")
        check(pipeline.first.map { rule.getString("@css:h1@text", from: $0) } == "Pipeline",
              "subsequent rule query uses the JS-returned document rather than original response")
    }
}
