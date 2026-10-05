import Foundation

final class FakeRPC: ResetRPC {
    var handler: (String, [String: Any]) throws -> [String: Any]
    init(_ handler: @escaping (String, [String: Any]) throws -> [String: Any]) { self.handler = handler }
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] { try handler(method, params) }
}
func runMonitorTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResetCardBar-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var passed = 0
    func check(_ test: Bool, _ label: String) throws {
        guard test else { throw Failure(message: label) }; passed += 1
    }
    func row(_ id: String = "card1", _ expiry: Double = 10500) -> [String: Any] {
        ["id": id, "status": "available", "resetType": "codexRateLimits", "expiresAt": expiry]
    }
    func response(_ rows: [[String: Any]]? = nil, count: Int = 1, account: String = "account-a") -> [String: Any] {
        ["accountId": account, "rateLimitResetCredits": ["availableCount": count, "credits": rows.map { $0 as Any } ?? NSNull()]]
    }
    func make(_ name: String) throws -> Monitor { try Monitor(file: root.appendingPathComponent(name + ".json"), now: { 10000 }) }
    // Lost consume response: key is durable before sending and replayed after restart even if the card vanished.
    let m = try make("lost")
    var firstKey = ""
    do {
        let result = try m.poll(FakeRPC { method, params in
            if method == "account/rateLimits/read" { return response([row()]) }
            firstKey = params["idempotencyKey"] as! String
            let disk = try Monitor(file: m.file)
            try check(disk.state.accounts["account-a"]?.pending["card1"]?.key == firstKey, "persist-before-send")
            throw Failure(message: "response lost")
        }, enabled: { true }, minutes: 60)
        try check(result.failed, "lost-response surfaced and retained")
    } catch { throw error }
    let restarted = try Monitor(file: m.file, now: { 11000 }) // already expired
    let recovered = try restarted.poll(FakeRPC { method, params in
        if method == "account/rateLimits/read" { return response([], count: 0) }
        try check(params["idempotencyKey"] as? String == firstKey, "restart reuses key after disappearance/expiry")
        return ["outcome": "alreadyRedeemed"]
    }, enabled: { true }, minutes: 60)
    try check(recovered.events.contains { $0.title == "重置卡已使用" }, "reconciled success event")
    try check(restarted.state.accounts["account-a"]?.completed == ["card1"], "success durable")
    // Post-consume read failure must not cause another redemption and must retain the success alert.
    let success = try make("post-success")
    var reads = 0, consumes = 0
    do {
        _ = try success.poll(FakeRPC { method, _ in
            if method == "account/rateLimits/read" {
                reads += 1; if reads > 1 { throw Failure(message: "read lost") }; return response([row()])
            }
            consumes += 1; return ["outcome": "reset"]
        }, enabled: { true }, minutes: 60)
    } catch {}
    let afterSuccess = try Monitor(file: success.file, now: { 10000 })
    _ = try afterSuccess.poll(FakeRPC { method, _ in
        try check(method == "account/rateLimits/read", "completed card never consumed again")
        return response([row()])
    }, enabled: { true }, minutes: 60)
    try check(consumes == 1 && afterSuccess.state.accounts["account-a"]?.outbox.count == 1, "post-success error preserves outbox")
    // No eligible windows: next poll is a distinct logical attempt; multiple cards are considered.
    let none = try make("nothing")
    var keys: [String] = [], ids: [String] = []
    let noWindows = FakeRPC { method, params in
        if method == "account/rateLimits/read" { return response([row("card2", 10600), row()], count: 2) }
        keys.append(params["idempotencyKey"] as! String); ids.append(params["creditId"] as! String)
        return ["outcome": "nothingToReset"]
    }
    _ = try none.poll(noWindows, enabled: { true }, minutes: 60)
    _ = try none.poll(noWindows, enabled: { true }, minutes: 60)
    try check(ids == ["card1", "card2", "card1", "card2"], "earliest expiry first, no starvation")
    try check(Set(keys).count == 4, "new keys after definitive nothingToReset")
    // Partial/null details retain known expirations, but a complete empty list clears them.
    let cache = try make("cache")
    _ = try cache.poll(FakeRPC { _, _ in response([row()]) }, enabled: { false }, minutes: 60)
    let partial = try cache.poll(FakeRPC { _, _ in response(nil) }, enabled: { false }, minutes: 60)
    try check(partial.cards.count == 1 && !partial.detailsKnown, "null details retain cache")
    let empty = try cache.poll(FakeRPC { _, _ in response([], count: 0) }, enabled: { false }, minutes: 60)
    try check(empty.cards.isEmpty, "complete empty list clears stale cards")
    // Initial failure, identity changes, disabled automatic mode, and corrupt storage fail safely.
    let initial = try make("initial")
    var called = 0
    do { _ = try initial.poll(FakeRPC { method, _ in
        called += 1; throw Failure(message: "offline")
    }, enabled: { true }, minutes: 60) } catch {}
    try check(called == 1 && initial.state.accounts.isEmpty, "failed read cannot redeem")
    let identity = try make("identity")
    var methods: [String] = []
    do { _ = try identity.poll(FakeRPC { method, _ in methods.append(method); return ["rateLimitResetCredits": ["credits": [row()]]] }, enabled: { true }, minutes: 60) } catch {}
    try check(methods == ["account/rateLimits/read"], "missing account ID blocks redemption")
    let switched = try make("switched")
    _ = try switched.poll(FakeRPC { method, _ in
        if method == "account/rateLimits/read" { return response([row()]) }
        throw Failure(message: "response lost")
    }, enabled: { false }, minutes: 60)
    let other = try switched.poll(FakeRPC { method, _ in
        try check(method == "account/rateLimits/read", "disabled mode never consumes")
        return response([], count: 0, account: "account-b")
    }, enabled: { true }, minutes: 60)
    try check(other.cards.isEmpty, "account cache isolation")
    try Data("invalid json".utf8).write(to: root.appendingPathComponent("corrupt.json"))
    var rejected = false
    do { _ = try make("corrupt") } catch { rejected = true }
    try check(rejected, "corrupt ledger must not regenerate keys")
    // Disk failure prevents transmitting consume, not just reporting an error afterward.
    let unwritable = try make("blocked")
    try FileManager.default.createDirectory(at: unwritable.file, withIntermediateDirectories: false)
    var sent = false
    do { _ = try unwritable.poll(FakeRPC { method, _ in
        if method.contains("consume") { sent = true }; return response([row()])
    }, enabled: { true }, minutes: 60) } catch {}
    try check(!sent, "storage write failure blocks consume")
    // Retry cadence is bounded and tightens near expiry or unknown request outcomes.
    try check(Monitor.interval(cards: [Card(row("x", 10100))!], now: 10000, failed: false, pending: false) == 5, "last-two-minutes cadence")
    try check(Monitor.interval(cards: [Card(row())!], now: 10000, failed: false, pending: false) == 15, "last-hour cadence")
    try check(Monitor.interval(cards: [], now: 10000, failed: true, pending: false) == 15, "network failure cadence")
    try check(Monitor.interval(cards: [], now: 10000, failed: false, pending: true) == 5, "uncertain outcome cadence")
    // Unknown results retain the key for safe retry.
    let unknown = try make("unknown")
    do { _ = try unknown.poll(FakeRPC { method, _ in method == "account/rateLimits/read" ? response([row()]) : ["outcome": "unexpected"] }, enabled: { true }, minutes: 60) } catch {}
    try check(unknown.state.accounts["account-a"]?.pending["card1"] != nil, "unknown outcome preserves pending attempt")
    let independent = try make("independent")
    var successfulID: String?
    let isolated = try independent.poll(FakeRPC { method, params in
        if method == "account/rateLimits/read" { return response([row(), row("card2", 10600)], count: 2) }
        let id = params["creditId"] as! String
        if id == "card1" { throw Failure(message: "card1 request failed") }
        successfulID = id; return ["outcome": "reset"]
    }, enabled: { true }, minutes: 60)
    try check(successfulID == "card2" && isolated.failed, "one-card failure cannot starve the next card")
    print("PASS: \(passed) monitor assertions (mock service only; no real credits consumed)")
}
