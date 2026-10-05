import Foundation
import Darwin

protocol ResetRPC {
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]
}
struct SavedCard: Codable {
    let id: String, status: String, type: String
    let expires: Double?
    var row: [String: Any] { ["id": id, "status": status, "resetType": type, "expiresAt": expires.map { $0 as Any } ?? NSNull()] }
    init(_ card: Card) { id = card.id; status = card.status; type = card.type; expires = card.expires }
}
struct Attempt: Codable { let key: String; let started: Double }
struct AccountState: Codable {
    var cards: [SavedCard] = []
    var pending: [String: Attempt] = [:]
    var completed: [String] = []
    var lastRead: Double = 0
    var lastOutcome: String?
    var outbox: [MonitorEvent] = []
}
struct MonitorState: Codable {
    var account: String?
    var accounts: [String: AccountState] = [:]
}
struct MonitorEvent: Codable {
    let id: String, title: String, body: String
}
struct MonitorResult {
    let count: Int?, cards: [Card], detailsKnown: Bool, message: String, events: [MonitorEvent]
    var failed: Bool = false
}
final class Monitor {
    let file: URL
    var state: MonitorState
    var now: () -> Double
    var legacyDefaults: UserDefaults?
    init(file: URL, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) throws {
        self.file = file; self.now = now
        if FileManager.default.fileExists(atPath: file.path) {
            // Never silently discard a corrupt ledger and create fresh redemption keys.
            state = try JSONDecoder().decode(MonitorState.self, from: Data(contentsOf: file))
        } else { state = MonitorState() }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    var cached: [Card] {
        guard let account = state.account, let saved = state.accounts[account] else { return [] }
        return saved.cards.filter { !saved.completed.contains($0.id) }.compactMap { Card($0.row) }
    }
    func poll(_ rpc: ResetRPC, enabled: () -> Bool, minutes: Double) throws -> MonitorResult {
        var response = try rpc.call("account/rateLimits/read", [:])
        guard let account = response["accountId"] as? String, !account.isEmpty else {
            throw Failure(message: "接口未提供账号标识，已暂停自动使用以避免用错账号")
        }
        let originalAccount = account
        state.account = account
        var events: [MonitorEvent] = []
        var info: String?
        var failures: [String] = []
        func absorb(_ response: [String: Any]) throws -> (Int?, Bool, [Card]) {
            guard response["accountId"] as? String == originalAccount else {
                throw Failure(message: "检查期间登录账号发生变化，已停止本轮自动使用")
            }
            let summary = response["rateLimitResetCredits"] as? [String: Any]
            let count = summary?["availableCount"] as? Int
            let rows = summary?["credits"] as? [[String: Any]]
            let fetched = rows?.compactMap(Card.init) ?? []
            var saved = state.accounts[account] ?? AccountState()
            if state.accounts[account] == nil, let legacyDefaults {
                saved.completed = legacyDefaults.stringArray(forKey: "completed." + account) ?? []
                let prefix = "attempt." + account + "."
                for (key, value) in legacyDefaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
                    if let uuid = value as? String { saved.pending[String(key.dropFirst(prefix.count))] = Attempt(key: uuid, started: now()) }
                }
            }
            // A complete response replaces the cache. Missing/capped detail rows preserve known IDs.
            let complete = count != nil && rows != nil && count! == fetched.count
            if complete { saved.cards = fetched.map(SavedCard.init) }
            else {
                var merged = Dictionary(saved.cards.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                for card in fetched { merged[card.id] = SavedCard(card) }
                saved.cards = Array(merged.values)
            }
            saved.lastRead = now()
            state.accounts[account] = saved; try save()
            return (count, rows != nil, saved.cards.compactMap { Card($0.row) }.filter { !saved.completed.contains($0.id) }.sorted { ($0.expires ?? .infinity) < ($1.expires ?? .infinity) })
        }
        var snapshot = try absorb(response)
        events += state.accounts[account]?.outbox ?? []
        // Pending requests are reconciled even if the card disappeared or expired after the response was lost.
        let pending = state.accounts[account]?.pending ?? [:]
        let due = (snapshot.0 == 0 ? [] : snapshot.2).filter { $0.due(now(), minutes: minutes) }.map(\.id)
        let expiry = Dictionary(snapshot.2.map { ($0.id, ($0.expires ?? .infinity) > now() ? ($0.expires ?? .infinity) : .infinity) }, uniquingKeysWith: { first, _ in first })
        let candidates = Array(Set(pending.keys).union(due)).sorted { (expiry[$0] ?? .infinity) == (expiry[$1] ?? .infinity) ? $0 < $1 : (expiry[$0] ?? .infinity) < (expiry[$1] ?? .infinity) }
        for id in candidates {
            guard enabled() else { break }
            var saved = state.accounts[account] ?? AccountState()
            if saved.completed.contains(id) { continue }
            let previous = saved.pending[id]
            if previous == nil {
                guard snapshot.2.contains(where: { $0.id == id && $0.due(now(), minutes: minutes) }) else { continue }
            }
            do {
            let attempt = previous ?? Attempt(key: UUID().uuidString, started: now())
            saved.pending[id] = attempt; state.accounts[account] = saved
            try save() // Durable key BEFORE the request crosses the process boundary.
            let result = try rpc.call("account/rateLimitResetCredit/consume", ["creditId": id, "idempotencyKey": attempt.key])
            guard let outcome = result["outcome"] as? String else { throw Failure(message: "重置响应缺少结果，将使用同一请求标识确认") }
            saved = state.accounts[account] ?? saved
            switch outcome {
            case "reset", "alreadyRedeemed":
                saved.completed.append(id); saved.pending.removeValue(forKey: id)
                saved.lastOutcome = "已确认使用重置卡 · " + Date(timeIntervalSince1970: now()).formatted(date: .numeric, time: .shortened)
                info = "已确认使用重置卡"
                let event = MonitorEvent(id: "success.\(account).\(id)", title: "重置卡已使用", body: "Codex 额度已重置，本次使用结果已确认。")
                saved.outbox.append(event); events.append(event)
            case "nothingToReset":
                saved.pending.removeValue(forKey: id)
                info = "暂无可重置额度，临近到期会持续重试"
            case "noCredit":
                saved.pending.removeValue(forKey: id)
                info = "卡片当前不可用，无法确认已使用"
                events.append(MonitorEvent(id: "unavailable.\(account).\(id)", title: "重置卡使用未成功", body: "服务端返回无可用卡。请打开 Codex 检查卡片状态。"))
            default:
                throw Failure(message: "未知重置结果 \(outcome)，保留请求记录以便确认")
            }
            state.accounts[account] = saved; try save()
            response = try rpc.call("account/rateLimits/read", [:])
            snapshot = try absorb(response)
            // After success, refreshed windows may no longer be eligible. Stop instead of wasting another card.
            if outcome == "reset" || outcome == "alreadyRedeemed" { break }
            } catch {
                failures.append(error.localizedDescription)
                events.append(MonitorEvent(id: "failure.\(account).\(id).\(Int(now() / 300))", title: "自动使用重置卡遇到异常", body: error.localizedDescription + "。已保留使用记录并继续重试，请检查网络和 Codex 登录。"))
                // Successful redemption plus failed refresh must not cause a second reset on stale windows.
                if state.accounts[account]?.completed.contains(id) == true { break }
                continue
            }
        }
        snapshot.2 = snapshot.2.filter { !(state.accounts[account]?.completed.contains($0.id) ?? false) }
        for card in snapshot.2 where card.status == "available" && card.type == "codexRateLimits" {
            guard let end = card.expires else { continue }
            let left = end - now()
            let stage: String
            if left <= 0 { stage = "expired" }
            else if left <= 120 { stage = "2m" }
            else if left <= 600 { stage = "10m" }
            else if left <= 3600 { stage = "1h" }
            else if left <= 86400 { stage = "24h" }
            else { continue }
            events.append(MonitorEvent(id: "expiry.\(account).\(card.id).\(stage)", title: left <= 0 ? "重置卡已到期" : "重置卡即将到期", body: left <= 0 ? "未能确认这张卡已使用，请查看 Codex。" : "剩余约 \(Int(ceil(left / 60))) 分钟。\(enabled() ? "自动使用已开启；无可重置额度时无法保证成功。" : "自动使用已关闭，请及时手动使用。")"))
        }
        if snapshot.0 == nil || !snapshot.1 || (snapshot.0 ?? 0) > snapshot.2.count {
            info = "卡片明细不完整，已保留已知到期时间并继续查询"
        }
        return MonitorResult(count: snapshot.0, cards: snapshot.2, detailsKnown: snapshot.1, message: failures.first.map { "自动使用异常，将继续重试：" + $0 } ?? info ?? "已连接 Codex", events: events, failed: !failures.isEmpty)
    }
    static func interval(cards: [Card], now: Double, failed: Bool, pending: Bool) -> Double {
        let end = cards.filter { $0.status == "available" }.compactMap(\.expires).filter { $0 > now }.min()
        if pending || end.map({ $0 - now <= 120 }) == true { return 5 }
        if failed || end.map({ $0 - now <= 3600 }) == true { return 15 }
        // Align to the next reminder threshold rather than polling past it.
        if let end {
            let boundaries: [Double] = [86400, 3600, 600, 120]
            let waits = boundaries.map { end - now - $0 }.filter { $0 > 0 }
            return min(60, waits.min() ?? 60)
        }
        return 60
    }
}
