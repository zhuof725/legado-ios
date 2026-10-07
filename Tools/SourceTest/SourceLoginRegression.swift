import Foundation

/// Offline, synthetic-value regression for SourceLoginStore.
/// Failure messages never include login values or cookies.
/// The shared runner must register `SourceLoginRegression.run` explicitly.
enum SourceLoginRegression {
    private struct ProbeError: Error {}

    private final class Recorder {
        private let lock = NSLock()
        private var replaced: [(String, String)] = []
        private var removed: [String] = []
        private var failReplace = false
        private var failRemove = false

        func setFailReplace(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            failReplace = value
        }

        func setFailRemove(_ value: Bool) {
            lock.lock(); defer { lock.unlock() }
            failRemove = value
        }

        func replace(_ key: String, _ cookie: String) throws {
            lock.lock()
            let fail = failReplace
            if !fail { replaced.append((key, cookie)) }
            lock.unlock()
            if fail { throw ProbeError() }
        }

        func remove(_ key: String) throws {
            lock.lock()
            let fail = failRemove
            removed.append(key)
            lock.unlock()
            if fail { throw ProbeError() }
        }

        var replaceCalls: [(String, String)] {
            lock.lock(); defer { lock.unlock() }
            return replaced
        }

        var removeCalls: [String] {
            lock.lock(); defer { lock.unlock() }
            return removed
        }
    }

    private static func makeStore(_ recorder: Recorder,
                                  nested: SourceLoginStore.NestedValuePolicy = .compactJSON)
        -> (SourceLoginStore, InMemorySourceLoginBackingStore) {
        let backing = InMemorySourceLoginBackingStore()
        let store = SourceLoginStore(
            backing: backing,
            cookieReplacer: { key, cookie in try recorder.replace(key, cookie) },
            cookieRemover: { key in try recorder.remove(key) },
            nestedValues: nested)
        return (store, backing)
    }

    static func run(_ check: (Bool, String) -> Void) {
        let a = "https://login-store.invalid/site#a"
        let b = "https://login-store.invalid/site#b"
        let other = "https://login-other.invalid/site"
        let ui = #"[{"name":"user","type":"text","default":"u-default"},{"name":"pass","type":"password"},{"name":"go","type":"button","action":"x"},{"name":"user","type":"text","default":"u-last"}]"#

        // 1. Isolation, including the same host with different # suffixes.
        do {
            let (store, _) = makeStore(Recorder())
            _ = store.putLoginInfo(a, #"{"k":"va"}"#)
            _ = store.putLoginInfo(b, #"{"k":"vb"}"#)
            check(store.getLoginInfoMap(a, loginUiJSON: nil) == ["k": "va"], "login info isolates # suffix a")
            check(store.getLoginInfoMap(b, loginUiJSON: nil) == ["k": "vb"], "login info isolates # suffix b")
            check(store.getLoginInfo(other) == nil, "login info isolates other host")
            try store.putLoginHeader(a, #"{"X-T":"ha"}"#)
            try store.putLoginHeader(b, #"{"X-T":"hb"}"#)
            check(store.getLoginHeaderMap(a) == ["X-T": "ha"], "header isolates # suffix a")
            check(store.getLoginHeaderMap(b) == ["X-T": "hb"], "header isolates # suffix b")
            check(store.getLoginHeader(other) == nil, "header isolates other host")
            store.removeLoginInfo(a)
            check(store.getLoginInfo(a) == nil && store.getLoginInfo(b) != nil, "removeLoginInfo only affects its source")
            check(SourceLoginStore.userInfoKey(a) == "userInfo_" + a, "userInfo key format keeps # suffix")
            check(SourceLoginStore.loginHeaderKey(a) == "loginHeader_" + a, "loginHeader key format keeps # suffix")
        } catch {
            check(false, "isolation case threw unexpectedly")
        }

        // 2. loginUi defaults, button filter, duplicate names, write-back.
        do {
            let (store, backing) = makeStore(Recorder())
            let map = store.getLoginInfoMap(a, loginUiJSON: ui)
            check(map == ["user": "u-last", "pass": ""], "loginUi: button filtered, later duplicate wins, missing default is empty")
            let saved = backing.get("userInfo_" + a)
            check(saved != nil, "loginUi result written back")
            check(store.getLoginInfo(a) == saved, "getLoginInfo returns written-back text")
            check(SourceLoginJSON.parseStringMap(saved ?? "", nested: .compactJSON) == map, "written-back JSON round-trips")
            let onlyButtons = store.getLoginInfoMap(b, loginUiJSON: #"[{"name":"go","type":"button"}]"#)
            check(onlyButtons.isEmpty && store.getLoginInfo(b) == nil, "no fields means empty map and no write-back")
            check(store.getLoginInfoMap(other, loginUiJSON: "[]").isEmpty && store.getLoginInfo(other) == nil, "empty array is not written back")
            check(store.getLoginInfoMap(other, loginUiJSON: "   ").isEmpty, "blank loginUi gives empty map")
        }

        // 3. Stored value wins over loginUi.
        do {
            let (store, _) = makeStore(Recorder())
            _ = store.putLoginInfo(a, #"{"user":"stored"}"#)
            check(store.getLoginInfoMap(a, loginUiJSON: ui) == ["user": "stored"], "stored value wins over loginUi")
            _ = store.putLoginInfo(b, "not an object")
            check(store.getLoginInfoMap(b, loginUiJSON: ui).isEmpty, "stored non-object JSON yields empty map without falling back")
            check(store.getLoginInfo(b) == "not an object", "putLoginInfo stores any string")
        }

        // 4. Invalid JSON.
        do {
            let (store, _) = makeStore(Recorder())
            for bad in ["{", "[1,", "nope", "[1]", #"{"a":1}"#, #"[{"name":1,"type":{}}]"#, "[{]"] {
                let map = store.getLoginInfoMap(other, loginUiJSON: bad)
                check(map.isEmpty, "invalid loginUi returns empty map")
            }
            check(store.getLoginInfo(other) == nil, "invalid loginUi is not written back")
            _ = store.putLoginInfo(a, "{broken")
            check(store.getLoginInfoMap(a, loginUiJSON: nil).isEmpty, "invalid stored JSON returns empty map")
            try? store.putLoginHeader(a, "{broken")
            check(store.getLoginHeaderMap(a) == nil, "invalid header JSON gives nil map")
            check(store.getLoginHeader(a) == "{broken", "invalid header JSON is still stored as text")
        }

        // 5. putLoginInfo / removeLoginInfo.
        do {
            let (store, _) = makeStore(Recorder())
            check(store.putLoginInfo(a, #"{"p":"q"}"#) == true, "putLoginInfo returns true")
            check(store.getLoginInfo(a) == #"{"p":"q"}"#, "getLoginInfo returns stored text verbatim")
            store.removeLoginInfo(a)
            check(store.getLoginInfo(a) == nil, "removeLoginInfo clears login info")
            check(store.getLoginInfoMap(a, loginUiJSON: nil).isEmpty, "map empty after removal")
        }

        // 6. putLoginHeader with Cookie / cookie.
        do {
            let rec = Recorder()
            let (store, _) = makeStore(rec)
            try store.putLoginHeader(a, #"{"Cookie":"sid=1; t=2","X-A":"1"}"#)
            check(rec.replaceCalls.count == 1
                  && rec.replaceCalls[0].0 == a
                  && rec.replaceCalls[0].1 == "sid=1; t=2", "Cookie header calls replacer with source key and cookie")
            check(store.getLoginHeaderMap(a) == ["Cookie": "sid=1; t=2", "X-A": "1"], "header stored after replacer succeeds")
            try store.putLoginHeader(b, #"{"cookie":"lc=9"}"#)
            check(rec.replaceCalls.count == 2 && rec.replaceCalls[1].0 == b && rec.replaceCalls[1].1 == "lc=9", "lowercase cookie key is honored")
            try store.putLoginHeader(b, #"{"Cookie":"up=1","cookie":"low=2"}"#)
            check(rec.replaceCalls.count == 3 && rec.replaceCalls[2].1 == "up=1", "Cookie takes precedence over cookie")
            try store.putLoginHeader(other, #"{"X-Only":"1"}"#)
            check(rec.replaceCalls.count == 3, "header without cookie does not call replacer")
        } catch {
            check(false, "cookie header case threw unexpectedly")
        }

        // 7. Replacer failure: header not saved, error rethrown.
        do {
            let rec = Recorder()
            let (store, _) = makeStore(rec)
            try store.putLoginHeader(a, #"{"X-Old":"1"}"#)
            rec.setFailReplace(true)
            var threw = false
            do {
                try store.putLoginHeader(a, #"{"Cookie":"sid=new"}"#)
            } catch {
                threw = error is ProbeError
            }
            check(threw, "replacer error is propagated unchanged")
            check(store.getLoginHeaderMap(a) == ["X-Old": "1"], "previous header kept when replacer fails")
            var threwFresh = false
            do {
                try store.putLoginHeader(b, #"{"Cookie":"sid=new"}"#)
            } catch {
                threwFresh = true
            }
            check(threwFresh && store.getLoginHeader(b) == nil, "header not saved when replacer fails on fresh source")
        } catch {
            check(false, "replacer failure setup threw unexpectedly")
        }

        // 8. removeLoginHeader.
        do {
            let rec = Recorder()
            let (store, _) = makeStore(rec)
            try store.putLoginHeader(a, #"{"X":"1"}"#)
            try store.putLoginHeader(b, #"{"X":"2"}"#)
            try store.removeLoginHeader(a)
            check(store.getLoginHeader(a) == nil, "removeLoginHeader deletes header")
            check(rec.removeCalls == [a], "removeLoginHeader calls remover with source key")
            check(store.getLoginHeader(b) != nil, "removeLoginHeader leaves other sources")
            rec.setFailRemove(true)
            var threw = false
            do {
                try store.removeLoginHeader(b)
            } catch {
                threw = error is ProbeError
            }
            check(threw, "remover error is propagated")
            check(store.getLoginHeader(b) == nil, "header deleted before remover runs")
        } catch {
            check(false, "removeLoginHeader case threw unexpectedly")
        }

        // 9. Value conversion.
        do {
            let (store, _) = makeStore(Recorder())
            _ = store.putLoginInfo(a, #"{"s":"text","n":12,"f":1.50,"t":true,"z":false,"nul":null,"o":{"k":[1,"x"]},"u":"\u4e2d\n"}"#)
            let map = store.getLoginInfoMap(a, loginUiJSON: nil)
            check(map["s"] == "text", "string kept verbatim")
            check(map["n"] == "12" && map["f"] == "1.50", "numbers keep JSON text")
            check(map["t"] == "true" && map["z"] == "false", "booleans become JSON text")
            check(map["nul"] == nil, "null values are skipped")
            check(map["o"] == #"{"k":[1,"x"]}"#, "nested value becomes compact JSON text")
            check(map["u"] == "\u{4e2d}\n", "unicode and escape sequences decoded")
            let (strict, _) = makeStore(Recorder(), nested: .rejectLikeGson)
            _ = strict.putLoginInfo(a, #"{"o":{"k":1}}"#)
            check(strict.getLoginInfoMap(a, loginUiJSON: nil).isEmpty, "rejectLikeGson policy fails nested values")
            _ = store.putLoginInfo(b, #"{"a":"1","a":"2"}"#)
            check(store.getLoginInfoMap(b, loginUiJSON: nil).isEmpty, "duplicate keys count as parse failure")
            let roundTrip = SourceLoginJSON.serializeStringMap(["q\"": "l1\nl2\\"])
            check(SourceLoginJSON.parseStringMap(roundTrip, nested: .compactJSON) == ["q\"": "l1\nl2\\"], "serializer escapes and parser round-trips")
        }

        // 10. Concurrent reads and writes. Every iteration owns a distinct key, so the
        // assertions are deterministic regardless of scheduling.
        do {
            let rec = Recorder()
            let (store, _) = makeStore(rec)
            let iterations = 48
            let counterLock = NSLock()
            var unexpected = 0
            DispatchQueue.concurrentPerform(iterations: iterations) { index in
                let key = "https://login-concurrent.invalid/" + String(index % 8) + "#" + String(index)
                let tag = String(index)
                _ = store.putLoginInfo(key, "{\"i\":\"" + tag + "\"}")
                var bad = store.getLoginInfoMap(key, loginUiJSON: nil) != ["i": tag]
                do {
                    try store.putLoginHeader(key, "{\"Cookie\":\"c=" + tag + "\"}")
                } catch {
                    bad = true
                }
                if store.getLoginHeaderMap(key)?["Cookie"] != "c=" + tag { bad = true }
                if index % 4 == 0 {
                    store.removeLoginInfo(key)
                    do { try store.removeLoginHeader(key) } catch { bad = true }
                    if store.getLoginInfo(key) != nil || store.getLoginHeader(key) != nil { bad = true }
                }
                if bad {
                    counterLock.lock()
                    unexpected += 1
                    counterLock.unlock()
                }
            }
            check(unexpected == 0, "concurrent per-source reads and writes stay consistent")
            check(rec.replaceCalls.count == iterations, "every concurrent putLoginHeader called the replacer once")
            check(rec.removeCalls.count == iterations / 4, "every concurrent removeLoginHeader called the remover once")
            // Shared-key contention: only checks the store survives and stays usable.
            let shared = "https://login-shared.invalid/x"
            DispatchQueue.concurrentPerform(iterations: 32) { index in
                if index % 2 == 0 {
                    _ = store.putLoginInfo(shared, "{\"i\":\"1\"}")
                } else {
                    _ = store.getLoginInfoMap(shared, loginUiJSON: ui)
                }
            }
            _ = store.putLoginInfo(shared, "{\"i\":\"final\"}")
            check(store.getLoginInfoMap(shared, loginUiJSON: nil) == ["i": "final"], "store usable after shared-key contention")
        }
    }
}
