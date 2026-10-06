import Foundation
import JavaScriptCore
import SwiftSoup

/// JavaScriptCore wrapper for the Jsoup Element/Elements objects exposed by Legado.
@objc protocol JSNodeExports: JSExport {
    func attr(_ name: String) -> String
    func text() -> String
    func ownText() -> String
    func html() -> String
    func outerHtml() -> String
    func select(_ selector: String) -> JSNodeListBridge
    func children() -> JSNodeListBridge
    func toArray() -> [Any]
    func toString() -> String
}

@objc protocol JSNodeListExports: JSExport {
    var length: Int { get }
    func size() -> Int
    func get(_ index: Int) -> JSNodeBridge?
    func toArray() -> [Any]
    func attr(_ name: String) -> String
    func text() -> String
    func ownText() -> String
    func html() -> String
    func outerHtml() -> String
    func toString() -> String
}

@objc final class JSNodeBridge: NSObject, JSNodeExports {
    let element: Element
    init(_ element: Element) { self.element = element; super.init() }

    func attr(_ name: String) -> String { (try? element.attr(name)) ?? "" }
    func text() -> String { (try? element.text()) ?? "" }
    func ownText() -> String { element.ownText() }
    func html() -> String { (try? element.html()) ?? "" }
    func outerHtml() -> String { (try? element.outerHtml()) ?? "" }
    func select(_ selector: String) -> JSNodeListBridge {
        JSNodeListBridge((try? element.select(selector).array()) ?? [])
    }
    func children() -> JSNodeListBridge { JSNodeListBridge(element.children().array()) }
    func toArray() -> [Any] { [self] }
    func toString() -> String { outerHtml() }
}

@objc final class JSNodeListBridge: NSObject, JSNodeListExports {
    let elements: [Element]
    init(_ elements: [Element]) { self.elements = elements; super.init() }

    var length: Int { elements.count }
    func size() -> Int { elements.count }
    func get(_ index: Int) -> JSNodeBridge? {
        guard elements.indices.contains(index) else { return nil }
        return JSNodeBridge(elements[index])
    }
    func toArray() -> [Any] { elements.map(JSNodeBridge.init) }
    private var first: Element? { elements.first }
    func attr(_ name: String) -> String { first.map { (try? $0.attr(name)) ?? "" } ?? "" }
    func text() -> String { first.map { (try? $0.text()) ?? "" } ?? "" }
    func ownText() -> String { first?.ownText() ?? "" }
    func html() -> String { first.map { (try? $0.html()) ?? "" } ?? "" }
    func outerHtml() -> String { first.map { (try? $0.outerHtml()) ?? "" } ?? "" }
    func toString() -> String { elements.map { (try? $0.outerHtml()) ?? "" }.joined() }
}
