import Foundation

// SourceLoginStore: 书源登录信息存储，对应 Kotlin BaseSource 的
// getLoginInfoMap / getLoginInfo / putLoginInfo / removeLoginInfo /
// getLoginHeader / getLoginHeaderMap / putLoginHeader / removeLoginHeader。
//
// 持久化声明：
// - 仅内存、进程内。默认后端 InMemorySourceLoginBackingStore 在 App 重启后全部丢失。
// - 不写磁盘、不用 Keychain。
// - 不加密：原版 userInfo_ 用 AES(androidId) 加密后存 CacheManager，这里存明文，
//   也不伪造加密（因为只在内存里，没有落盘泄露面）。若以后接入持久化后端，
//   由后端负责加密或放入 Keychain。
// - 不输出任何日志；本文件不定义携带登录值的错误。
//
// 键名与 Kotlin 一致：
//   userInfo_<书源完整标识>、loginHeader_<书源完整标识>
// 书源完整标识由调用方传入，原样使用，保留 "#" 后缀（同域名不同 # 后缀互相隔离）。
//
// JSON 值转字符串规则（与 Gson 读取 Map<String,String> 的行为对照）：
// - 字符串：原样。                         Gson：相同。
// - 数字：按 JSON 原文，如 1.50 -> "1.50"。  Gson：相同（nextString 返回原文）。
// - 布尔：true / false。                   Gson：相同。
// - null：该键被跳过。                      Gson：map 里该键值为 null（Swift 的
//   [String:String] 无法表示），这是已知差异。
// - 嵌套对象/数组：默认 .compactJSON，转成紧凑 JSON 文本。
//   Gson 实际行为（据 Gson TypeAdapters.STRING 的实现，未在本环境运行验证）：
//   遇到 BEGIN_OBJECT/BEGIN_ARRAY 会抛 IllegalStateException，整个解析失败，
//   getOrNull 得 null，即返回空 map。这是已知差异；需要与原版完全一致时，
//   构造时传 nestedValues: .rejectLikeGson。
// - 重复键：Gson 的 Map 适配器遇重复键抛异常 -> 空 map。本实现同样视为解析失败。
// - 顶层不是对象（数组、字符串、数字等）或有多余尾部内容：视为解析失败 -> 空 map。
// - 解析器严格遵循标准 JSON（不支持 Gson lenient 的单引号、无引号键、注释等），
//   嵌套深度上限 64，超过视为失败。
// - 回存 JSON 的键按字典序排序（原版是 LinkedHashMap 的插入顺序，Swift 字典无序），
//   且不做 Gson 的 HTML 转义（\u003c 等），语义等价。

/// 登录信息的键值后端。实现必须线程安全。
protocol SourceLoginBackingStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

/// 纯内存后端，进程内有效，重启后丢失。
final class InMemorySourceLoginBackingStore: SourceLoginBackingStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    init() {}

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

final class SourceLoginStore {
    /// 嵌套对象/数组值的处理方式，见文件头注释。
    enum NestedValuePolicy {
        /// 转成紧凑 JSON 文本（默认）。
        case compactJSON
        /// 与 Gson 一致：整个对象解析失败。
        case rejectLikeGson
    }

    private let backing: SourceLoginBackingStore
    private let cookieReplacer: (String, String) throws -> Void
    private let cookieRemover: (String) throws -> Void
    private let nestedValues: NestedValuePolicy
    // 保护 "读 - 解析 - 回存" 序列。不会在持锁期间调用外部闭包。
    private let lock = NSLock()

    /// - cookieReplacer: (sourceKey, cookie) 对应 CookieStore.replaceCookie(key, cookie)
    /// - cookieRemover: (sourceKey) 对应 CookieStore.removeCookie(key)
    /// 闭包抛出的错误原样向上抛，本类不包装、不记录。
    init(backing: SourceLoginBackingStore,
         cookieReplacer: @escaping (String, String) throws -> Void,
         cookieRemover: @escaping (String) throws -> Void,
         nestedValues: NestedValuePolicy = .compactJSON) {
        self.backing = backing
        self.cookieReplacer = cookieReplacer
        self.cookieRemover = cookieRemover
        self.nestedValues = nestedValues
    }

    static func userInfoKey(_ sourceKey: String) -> String {
        return "userInfo_" + sourceKey
    }

    static func loginHeaderKey(_ sourceKey: String) -> String {
        return "loginHeader_" + sourceKey
    }

    // MARK: - 登录信息 (userInfo_)

    /// 对应 getLoginInfo()：未保存返回 nil。
    func getLoginInfo(_ sourceKey: String) -> String? {
        return backing.get(SourceLoginStore.userInfoKey(sourceKey))
    }

    /// 对应 getLoginInfoMap()。
    /// loginUiJSON 必须是已经求值完毕的 JSON 数组文本；"@js:" / "<js>" 形式的 loginUi
    /// 由调用方（JS 接入层）先求值再传入，本类不执行 JS。
    /// 1. 已保存的登录信息优先。解析成功返回 map；保存的内容不是对象 JSON 时返回空 map
    ///    （与原版一致：原版 putLoginInfo 对任意字符串都存，读取时才解析失败，且不回退到 loginUi）。
    /// 2. 否则解析 loginUiJSON：过滤 type == "button"，name 重复取后者，default 缺省为 ""。
    ///    至少有一项才回存。非法 JSON 或空白返回空 map，不崩溃。
    func getLoginInfoMap(_ sourceKey: String, loginUiJSON: String?) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        let storageKey = SourceLoginStore.userInfoKey(sourceKey)
        if let stored = backing.get(storageKey) {
            return SourceLoginJSON.parseStringMap(stored, nested: nestedValues) ?? [:]
        }
        guard let ui = loginUiJSON else { return [:] }
        if SourceLoginJSON.isBlank(ui) { return [:] }
        guard let map = SourceLoginJSON.parseLoginUi(ui), !map.isEmpty else { return [:] }
        backing.set(storageKey, SourceLoginJSON.serializeStringMap(map))
        return map
    }

    /// 对应 putLoginInfo(info)：对任意字符串都保存并返回 true。
    /// 内存后端不会失败；原版加密失败才返回 false，这里没有对应路径。
    @discardableResult
    func putLoginInfo(_ sourceKey: String, _ json: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        backing.set(SourceLoginStore.userInfoKey(sourceKey), json)
        return true
    }

    /// 对应 removeLoginInfo()。
    func removeLoginInfo(_ sourceKey: String) {
        lock.lock()
        defer { lock.unlock() }
        backing.remove(SourceLoginStore.userInfoKey(sourceKey))
    }

    // MARK: - 登录头 (loginHeader_)

    /// 对应 getLoginHeader()。
    func getLoginHeader(_ sourceKey: String) -> String? {
        return backing.get(SourceLoginStore.loginHeaderKey(sourceKey))
    }

    /// 对应 getLoginHeaderMap()：未保存或解析失败返回 nil。
    func getLoginHeaderMap(_ sourceKey: String) -> [String: String]? {
        guard let cache = getLoginHeader(sourceKey) else { return nil }
        return SourceLoginJSON.parseStringMap(cache, nested: nestedValues)
    }

    /// 对应 putLoginHeader(header)。
    /// 若 header 解析为对象且含 "Cookie"（优先）或 "cookie" 键，先调用 cookieReplacer(sourceKey, cookie)；
    /// 成功后才保存 header。闭包抛错时 header 不保存，错误原样向上抛。
    /// header 不是合法对象 JSON 时不触发 cookie 闭包，但仍原样保存（与原版一致）。
    func putLoginHeader(_ sourceKey: String, _ json: String) throws {
        if let map = SourceLoginJSON.parseStringMap(json, nested: nestedValues) {
            if let cookie = map["Cookie"] ?? map["cookie"] {
                try cookieReplacer(sourceKey, cookie)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        backing.set(SourceLoginStore.loginHeaderKey(sourceKey), json)
    }

    /// 对应 removeLoginHeader()：先删 header，再调用 cookieRemover(sourceKey)。
    /// cookieRemover 抛错时 header 已被删除，错误向上抛（与原版顺序一致）。
    func removeLoginHeader(_ sourceKey: String) throws {
        lock.lock()
        backing.remove(SourceLoginStore.loginHeaderKey(sourceKey))
        lock.unlock()
        try cookieRemover(sourceKey)
    }
}

// MARK: - 内部 JSON 工具（保留数字原文，检测重复键，便于与 Gson 行为对照）

enum SourceLoginJSON {
    struct Member {
        let key: String
        let value: Value
    }

    indirect enum Value {
        case null
        case bool(Bool)
        case number(String)
        case string(String)
        case array([Value])
        case object([Member])
    }

    static func isBlank(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r":
                continue
            default:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                return false
            }
        }
        return true
    }

    /// 解析为 [String:String]；失败返回 nil。规则见 SourceLoginStore 文件头注释。
    static func parseStringMap(_ text: String,
                               nested: SourceLoginStore.NestedValuePolicy) -> [String: String]? {
        var parser = Parser(text)
        guard let doc = parser.parseDocument() else { return nil }
        guard case .object(let members) = doc else { return nil }
        var result: [String: String] = [:]
        var seen = Set<String>()
        for member in members {
            if seen.contains(member.key) { return nil }
            seen.insert(member.key)
            switch member.value {
            case .null:
                continue
            case .array, .object:
                if nested == .rejectLikeGson { return nil }
                result[member.key] = serialize(member.value)
            default:
                guard let s = scalarText(member.value) else { return nil }
                result[member.key] = s
            }
        }
        return result
    }

    /// 解析 loginUi JSON 数组为 name -> default（过滤 button，后者覆盖前者）。失败返回 nil。
    /// 仅读取 name/type/default 三个字段；其它字段（action/chars/style 等）被忽略，
    /// 它们类型不合法时 Gson 会整体失败而本实现不会，这是已知限制。
    static func parseLoginUi(_ text: String) -> [String: String]? {
        var parser = Parser(text, lenient: true)
        guard let doc = parser.parseDocument() else { return nil }
        guard case .array(let items) = doc else { return nil }
        var result: [String: String] = [:]
        for item in items {
            guard case .object(let members) = item else { return nil }
            var name = ""
            var type = "text"
            var def = ""
            for member in members {
                switch member.key {
                case "name":
                    guard let s = fieldText(member.value) else { return nil }
                    name = s ?? ""
                case "type":
                    guard let s = fieldText(member.value) else { return nil }
                    type = s ?? "text"
                case "default":
                    guard let s = fieldText(member.value) else { return nil }
                    def = s ?? ""
                default:
                    continue
                }
            }
            if type == "button" { continue }
            result[name] = def
        }
        return result
    }

    /// 字符串字段：标量转文本，null 返回 .some(nil)，嵌套结构返回 nil（失败）。
    private static func fieldText(_ value: Value) -> String?? {
        switch value {
        case .null:
            return .some(nil)
        case .array, .object:
            return nil
        default:
            guard let s = scalarText(value) else { return nil }
            return .some(s)
        }
    }

    private static func scalarText(_ value: Value) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    // MARK: 序列化（紧凑）

    static func serializeStringMap(_ map: [String: String]) -> String {
        var out = "{"
        var first = true
        for key in map.keys.sorted() {
            if !first { out += "," }
            first = false
            out += quote(key)
            out += ":"
            out += quote(map[key] ?? "")
        }
        out += "}"
        return out
    }

    static func serialize(_ value: Value) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .number(let n):
            return n
        case .string(let s):
            return quote(s)
        case .array(let items):
            var out = "["
            var first = true
            for item in items {
                if !first { out += "," }
                first = false
                out += serialize(item)
            }
            out += "]"
            return out
        case .object(let members):
            var out = "{"
            var first = true
            for member in members {
                if !first { out += "," }
                first = false
                out += quote(member.key)
                out += ":"
                out += serialize(member.value)
            }
            out += "}"
            return out
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: 解析器

    struct Parser {
        private let s: [Unicode.Scalar]
        private var i = 0
        private let maxDepth = 64
        /// 宽松模式仅用于 loginUi（Legado 用 lenient Gson 读取）：
        /// 支持无引号键、单引号字符串、无引号值、尾逗号、// 与 /* */ 注释。
        private let lenient: Bool

        init(_ text: String, lenient: Bool = false) {
            s = Array(text.unicodeScalars)
            self.lenient = lenient
        }

        mutating func parseDocument() -> Value? {
            skipWhitespace()
            guard let value = parseValue(depth: 0) else { return nil }
            skipWhitespace()
            return i == s.count ? value : nil
        }

        private mutating func skipWhitespace() {
            while i < s.count {
                let c = s[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                } else if lenient && c == "/" && i + 1 < s.count && s[i + 1] == "/" {
                    while i < s.count && s[i] != "\n" { i += 1 }
                } else if lenient && c == "/" && i + 1 < s.count && s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count && !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i = min(i + 2, s.count)
                } else {
                    break
                }
            }
        }

        private mutating func parseValue(depth: Int) -> Value? {
            if depth > maxDepth { return nil }
            guard i < s.count else { return nil }
            let c = s[i]
            switch c {
            case "{":
                return parseObject(depth: depth)
            case "[":
                return parseArray(depth: depth)
            case "\"":
                guard let str = parseString() else { return nil }
                return .string(str)
            case "'" where lenient:
                guard let str = parseString() else { return nil }
                return .string(str)
            default:
                let start = i
                if !lenient {
                    switch c {
                    case "t": return consumeLiteral("true") ? .bool(true) : nil
                    case "f": return consumeLiteral("false") ? .bool(false) : nil
                    case "n": return consumeLiteral("null") ? .null : nil
                    default: return parseNumber()
                    }
                }
                if let word = parseBareWord() {
                    switch word {
                    case "true": return .bool(true)
                    case "false": return .bool(false)
                    case "null": return .null
                    default: break
                    }
                    i = start
                    if let number = parseNumber(), i == start + word.unicodeScalars.count {
                        return number
                    }
                    i = start + word.unicodeScalars.count
                    return .string(word)
                }
                return nil
            }
        }

        /// 宽松模式下的无引号词：到分隔符或空白为止。
        private mutating func parseBareWord() -> String? {
            let start = i
            while i < s.count {
                let c = s[i]
                if c == "," || c == ":" || c == "}" || c == "]" || c == "{" || c == "["
                    || c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\"" || c == "'" {
                    break
                }
                i += 1
            }
            if i == start { return nil }
            var text = ""
            for k in start..<i { text.unicodeScalars.append(s[k]) }
            return text
        }

        private mutating func consumeLiteral(_ word: String) -> Bool {
            let scalars = Array(word.unicodeScalars)
            if i + scalars.count > s.count { return false }
            for k in 0..<scalars.count where s[i + k] != scalars[k] {
                return false
            }
            i += scalars.count
            return true
        }

        private func isDigit(_ c: Unicode.Scalar) -> Bool {
            return c.value >= 0x30 && c.value <= 0x39
        }

        private mutating func parseNumber() -> Value? {
            let start = i
            if i < s.count && s[i] == "-" { i += 1 }
            guard i < s.count, isDigit(s[i]) else { return nil }
            if s[i] == "0" {
                i += 1
            } else {
                while i < s.count && isDigit(s[i]) { i += 1 }
            }
            if i < s.count && s[i] == "." {
                i += 1
                guard i < s.count, isDigit(s[i]) else { return nil }
                while i < s.count && isDigit(s[i]) { i += 1 }
            }
            if i < s.count && (s[i] == "e" || s[i] == "E") {
                i += 1
                if i < s.count && (s[i] == "+" || s[i] == "-") { i += 1 }
                guard i < s.count, isDigit(s[i]) else { return nil }
                while i < s.count && isDigit(s[i]) { i += 1 }
            }
            var text = ""
            for k in start..<i { text.unicodeScalars.append(s[k]) }
            return .number(text)
        }

        private mutating func parseHex4() -> UInt32? {
            if i + 4 > s.count { return nil }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = s[i].value
                let digit: UInt32
                if c >= 0x30 && c <= 0x39 {
                    digit = c - 0x30
                } else if c >= 0x61 && c <= 0x66 {
                    digit = c - 0x61 + 10
                } else if c >= 0x41 && c <= 0x46 {
                    digit = c - 0x41 + 10
                } else {
                    return nil
                }
                value = value * 16 + digit
                i += 1
            }
            return value
        }

        private mutating func parseString() -> String? {
            guard i < s.count, s[i] == "\"" || (lenient && s[i] == "'") else { return nil }
            let quote = s[i]
            i += 1
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == quote {
                    i += 1
                    return String(out)
                }
                if c == "\\" {
                    i += 1
                    guard i < s.count else { return nil }
                    let e = s[i]
                    i += 1
                    switch e {
                    case "\"": out.append("\"")
                    case "'" where lenient: out.append("'")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append(Unicode.Scalar(UInt8(8)))
                    case "f": out.append(Unicode.Scalar(UInt8(12)))
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard let first = parseHex4() else { return nil }
                        var code = first
                        if first >= 0xD800 && first <= 0xDBFF {
                            // 高代理项：尝试与随后的 \uDC00-\uDFFF 合并，否则用替换字符。
                            if i + 1 < s.count && s[i] == "\\" && s[i + 1] == "u" {
                                let save = i
                                i += 2
                                if let second = parseHex4(), second >= 0xDC00 && second <= 0xDFFF {
                                    code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                                } else {
                                    i = save
                                    code = 0xFFFD
                                }
                            } else {
                                code = 0xFFFD
                            }
                        } else if first >= 0xDC00 && first <= 0xDFFF {
                            code = 0xFFFD
                        }
                        out.append(Unicode.Scalar(code) ?? Unicode.Scalar(UInt32(0xFFFD))!)
                    default:
                        return nil
                    }
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return nil
        }

        private mutating func parseArray(depth: Int) -> Value? {
            i += 1 // [
            var items: [Value] = []
            skipWhitespace()
            if i < s.count && s[i] == "]" {
                i += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                guard let v = parseValue(depth: depth + 1) else { return nil }
                items.append(v)
                skipWhitespace()
                guard i < s.count else { return nil }
                if s[i] == "," {
                    i += 1
                    if lenient {
                        skipWhitespace()
                        if i < s.count && s[i] == "]" {
                            i += 1
                            return .array(items)
                        }
                    }
                    continue
                }
                if s[i] == "]" {
                    i += 1
                    return .array(items)
                }
                return nil
            }
        }

        private mutating func parseObject(depth: Int) -> Value? {
            i += 1 // {
            var members: [Member] = []
            skipWhitespace()
            if i < s.count && s[i] == "}" {
                i += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                let parsedKey: String?
                if lenient && i < s.count && s[i] != "\"" && s[i] != "'" {
                    parsedKey = parseBareWord()
                } else {
                    parsedKey = parseString()
                }
                guard let key = parsedKey else { return nil }
                skipWhitespace()
                guard i < s.count, s[i] == ":" else { return nil }
                i += 1
                skipWhitespace()
                guard let v = parseValue(depth: depth + 1) else { return nil }
                members.append(Member(key: key, value: v))
                skipWhitespace()
                guard i < s.count else { return nil }
                if s[i] == "," {
                    i += 1
                    if lenient {
                        skipWhitespace()
                        if i < s.count && s[i] == "}" {
                            i += 1
                            return .object(members)
                        }
                    }
                    continue
                }
                if s[i] == "}" {
                    i += 1
                    return .object(members)
                }
                return nil
            }
        }
    }
}
