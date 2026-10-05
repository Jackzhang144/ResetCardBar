import AppKit
import SwiftUI
import Combine
import Network
import IOKit.pwr_mgt
import Darwin
import UserNotifications
import ServiceManagement

struct Card {
    let id: String
    let status: String
    let expires: Double?
    let type: String
    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = id; status = row["status"] as? String ?? "unknown"
        expires = (row["expiresAt"] as? NSNumber)?.doubleValue
        type = row["resetType"] as? String ?? ""
    }
    func due(_ now: Double, minutes: Double) -> Bool {
        guard status == "available", type == "codexRateLimits", let end = expires else { return false }
        return end > now && end - now <= minutes * 60
    }
}
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
// One RPC stream per refresh; all requests run on a serial worker queue.
final class RPC: ResetRPC {
    let process = Process(), input = Pipe(), output = Pipe()
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var responses: [Int: [String: Any]] = [:]
    var buffer = Data(), nextID = 0
    var ended = false
    init(path: String) throws {
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { self.lock.lock(); self.ended = true; self.lock.unlock(); self.semaphore.signal(); return }
            self.lock.lock()
            self.buffer.append(chunk)
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                self.buffer.removeSubrange(...newline)
                if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let id = message["id"] as? Int {
                    self.responses[id] = message; self.semaphore.signal()
                }
            }
            self.lock.unlock()
        }
        try process.run()
        do {
            _ = try call("initialize", ["clientInfo": ["name": "reset_card_bar", "version": "1.0.0"], "capabilities": ["experimentalApi": true]])
            try send(["method": "initialized"])
        } catch { close(); throw error }
    }
    func send(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1; let id = nextID
        try send(["method": method, "id": id, "params": params])
        let deadline = DispatchTime.now() + 12
        while true {
            lock.lock(); let message = responses.removeValue(forKey: id); let closed = ended; lock.unlock()
            if let message {
                if let error = message["error"] as? [String: Any] {
                    throw Failure(message: error["message"] as? String ?? "Codex 接口错误")
                }
                guard let result = message["result"] as? [String: Any] else { throw Failure(message: "接口响应格式异常") }
                return result
            }
            if closed { throw Failure(message: "Codex 输出流已关闭") }
            if semaphore.wait(timeout: deadline) == .timedOut { throw Failure(message: "Codex 请求超时，稍后自动重试") }
            if !process.isRunning { throw Failure(message: "Codex 服务已退出") }
        }
    }
    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let child = process
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
    }
    deinit { close() }
}

final class App: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let popover = NSPopover()
    var previewWindow: NSWindow?
    var hasError = false
    var showSettings = false
    var cardPage = 0
    var activeAccount: String?
    var monitor: Monitor?
    var monitorError: String?
    var notificationWarning: String?
    var notificationInFlight = Set<String>()
    var hasPendingAttempt = false
    var idleAssertion: IOPMAssertionID = 0
    var activity: NSObjectProtocol?
    let network = NWPathMonitor()
    let stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ResetCardBar/state.json")
    let defaults = UserDefaults.standard
    let worker = DispatchQueue(label: "ResetCardBar.rpc")
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?, busy = false, cards: [Card] = [], count: Int?, detailsKnown = false
    var message = "正在连接 Codex…", lastRefresh: Date?
    var auto: Bool { defaults.object(forKey: "auto") == nil || defaults.bool(forKey: "auto") }
    var minutes: Double { let n = defaults.double(forKey: "minutes"); return n > 0 ? n : 60 }
    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "持续监控重置卡到期时间")
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            DispatchQueue.main.async { self.checkNotifications(error: error) }
        }
        // Explicitly approved preference migration, applied once across upgrades.
        if !defaults.bool(forKey: "safety60Migrated") {
            defaults.set(60, forKey: "minutes"); defaults.set(true, forKey: "safety60Migrated")
        }
        do {
            monitor = try Monitor(file: stateURL)
            monitor!.legacyDefaults = defaults
            cards = monitor!.cached; activeAccount = monitor!.state.account
            if let last = monitor!.state.account.flatMap({ monitor!.state.accounts[$0]?.lastOutcome }) { defaults.set(last, forKey: "lastOutcome") }
        } catch { monitorError = "无法读取使用记录，自动使用暂停：" + error.localizedDescription }
        network.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { DispatchQueue.main.async { self?.refresh() } }
        }
        network.start(queue: DispatchQueue(label: "ResetCardBar.network"))
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 580)
        popover.contentViewController = NSHostingController(rootView: Dashboard(app: self))
        status.button?.target = self
        status.button?.action = #selector(showPanel)
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "重置卡助手 · 预览"
            window.contentViewController = NSHostingController(rootView: Dashboard(app: self))
            window.center(); window.makeKeyAndOrderFront(nil); previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
        if let account = monitor?.state.account { scheduleReminders(account: account) }
        render(); refresh()

    }
    func executable() throws -> String {
        let candidates = [defaults.string(forKey: "codexPath") ?? "", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        guard let path = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(message: "找不到 Codex，请在菜单中选择 codex 程序")
        }
        return path
    }
    @objc func woke() { refresh() }
    func scheduleNext(failed: Bool) {
        timer?.invalidate()
        let delay = Monitor.interval(cards: cards, now: Date().timeIntervalSince1970, failed: failed, pending: hasPendingAttempt && auto)
        timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
        updateSleepProtection()
    }
    func updateSleepProtection() {
        let urgent = auto && cards.contains { $0.due(Date().timeIntervalSince1970, minutes: max(60, minutes)) }
        if urgent && idleAssertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "临近重置卡到期，等待自动使用" as CFString, &idleAssertion)
            if result != kIOReturnSuccess { idleAssertion = 0; message = "防止空闲睡眠失败，请保持 Mac 醒着" }
        } else if !urgent && idleAssertion != 0 { IOPMAssertionRelease(idleAssertion); idleAssertion = 0 }
    }
    @objc func refresh() {
        guard !busy else { return }; busy = true; objectWillChange.send()
        timer?.invalidate()
        checkNotifications()
        let threshold = minutes
        worker.async { [self] in
            do {
                guard let monitor else { throw Failure(message: monitorError ?? "使用记录未初始化") }
                let rpc = try RPC(path: executable()); defer { rpc.close() }
                let result = try monitor.poll(rpc, enabled: { self.auto }, minutes: threshold)
                let pending = monitor.state.account.flatMap { monitor.state.accounts[$0]?.pending.isEmpty } == false
                let outcome = monitor.state.account.flatMap { monitor.state.accounts[$0]?.lastOutcome }
                let account = monitor.state.account ?? ""
                DispatchQueue.main.async {
                    self.activeAccount = account; self.count = result.count; self.detailsKnown = result.detailsKnown; self.cards = result.cards
                    self.lastRefresh = Date(); self.message = result.message; self.hasPendingAttempt = pending
                    if let outcome { self.defaults.set(outcome, forKey: "lastOutcome") }
                    for event in result.events { self.notify(event.title, event.body, id: event.id, once: true) }
                    self.scheduleReminders(account: account)
                    self.busy = false; self.render(error: result.failed); self.scheduleNext(failed: result.failed)
                }
            } catch {
                let cached = monitor?.cached ?? []
                let pending = monitor?.state.account.flatMap { monitor?.state.accounts[$0]?.pending.isEmpty } == false
                let account = monitor?.state.account ?? "unknown"
                let outbox = monitor?.state.account.flatMap { monitor?.state.accounts[$0]?.outbox } ?? []
                let outcome = monitor?.state.account.flatMap { monitor?.state.accounts[$0]?.lastOutcome }
                DispatchQueue.main.async {
                    self.cards = cached; self.hasPendingAttempt = pending
                    for event in outbox { self.notify(event.title, event.body, id: event.id, once: true) }
                    if let outcome { self.defaults.set(outcome, forKey: "lastOutcome") }
                    for card in cached where card.status == "available" && card.expires.map({ $0 <= Date().timeIntervalSince1970 }) == true {
                        self.notify("重置卡已到期，使用结果尚未确认", "监控遇到异常，无法确认这张卡是否已使用。请查看 Codex。", id: "expiry.\(account).\(card.id).expired", once: true)
                    }
                    self.message = error.localizedDescription; self.busy = false; self.render(error: true)
                    let urgent = cached.contains { $0.due(Date().timeIntervalSince1970, minutes: 60) }
                    let cooldown: Double = urgent ? 300 : 1800
                    if Date().timeIntervalSince1970 - self.defaults.double(forKey: "lastErrorAlert") > cooldown {
                        self.notify(urgent ? "重置卡临近到期，自动使用遇到异常" : "重置卡监控异常", error.localizedDescription + "。应用会继续重试，请检查网络或 Codex 登录。", id: "monitor.failure") {
                            self.defaults.set(Date().timeIntervalSince1970, forKey: "lastErrorAlert")
                        }
                    }
                    self.scheduleNext(failed: true)
                }
            }
        }
    }
    func checkNotifications(error: Error? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationWarning = error.map { "通知失败：" + $0.localizedDescription }
                if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                    self.notificationWarning = "通知未获授权，请在系统设置中开启；自动使用仍会运行"
                } else if settings.alertSetting == .disabled { self.notificationWarning = "通知横幅已关闭，请在系统设置中开启" }
                self.objectWillChange.send()
            }
        }
    }
    func scheduleReminders(account: String) {
        // System-owned reminders survive app exit. A successful redemption cancels its future reminders.
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            DispatchQueue.main.async {
                self.applyReminderSchedule(account: account, pending: pending)
            }
        }
    }
    func applyReminderSchedule(account: String, pending: [UNNotificationRequest]) {
        guard account == activeAccount else { return }
        let center = UNUserNotificationCenter.current()
        var valid = Set<String>()
        let now = Date().timeIntervalSince1970
        for card in cards where card.status == "available" && card.type == "codexRateLimits" {
            guard let end = card.expires, end > now else { continue }
            for (stage, offset) in [("24h", 86400.0), ("1h", 3600.0), ("10m", 600.0), ("2m", 120.0)] {
                let id = "expiry.\(account).\(card.id).\(stage)"
                let fire = end - offset
                guard fire > now + 1 else { continue }
                valid.insert(id)
                if pending.contains(where: { $0.identifier == id && ($0.content.userInfo["expiresAt"] as? Double) == end }) { continue }
                let content = UNMutableNotificationContent(); content.title = "重置卡即将到期"
                content.userInfo = ["expiresAt": end]
                content.body = "到期：\(date(end))。请确认自动使用正常运行；Mac 关机或合盖睡眠期间无法使用。"; content.sound = .default
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire - now, repeats: false))) { error in
                    if error == nil { self.defaults.set(fire, forKey: "scheduled." + id) }
                    else { DispatchQueue.main.async { self.notificationWarning = "系统提醒安排失败：" + error!.localizedDescription; self.objectWillChange.send() } }
                }
            }
        }
        let old = defaults.stringArray(forKey: "pendingReminderIDs") ?? []
        let remove = old.filter { !valid.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: remove)
        for id in remove { defaults.removeObject(forKey: "scheduled." + id) }
        defaults.set(Array(valid), forKey: "pendingReminderIDs")
    }
    func date(_ seconds: Double) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"; return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }
    func notify(_ title: String, _ body: String, id: String, once: Bool = false, accepted: (() -> Void)? = nil) {
        guard !notificationInFlight.contains(id), !once || !defaults.bool(forKey: "sent." + id) else { return }
        notificationInFlight.insert(id)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async { self.notificationInFlight.remove(id); self.checkNotifications() }; return
            }
            center.getDeliveredNotifications { delivered in
                if once && delivered.contains(where: { $0.request.identifier == id }) {
                    self.defaults.set(true, forKey: "sent." + id)
                    DispatchQueue.main.async { self.notificationInFlight.remove(id) }; return
                }
                let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                    DispatchQueue.main.async {
                        self.notificationInFlight.remove(id)
                        if let error { self.notificationWarning = "通知提交失败：" + error.localizedDescription; self.objectWillChange.send() }
                        else { if once { self.defaults.set(true, forKey: "sent." + id) }; accepted?() }
                    }
                }
            }
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound, .list]) }
    @objc func showPanel() {
        guard let button = status.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    func render(error: Bool = false) {
        hasError = error
        status.button?.image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: "重置卡") ?? NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重置卡")
        status.button?.imagePosition = .imageLeading
        status.button?.title = " \(error ? "!" : count.map(String.init) ?? "—")"
        status.button?.toolTip = "Codex 重置卡：\(message)"
        objectWillChange.send()
    }
    func setMinutes(_ value: Int) { defaults.set(value, forKey: "minutes"); updateSleepProtection(); render(); refresh() }
    @objc func toggleAuto() { defaults.set(!auto, forKey: "auto"); updateSleepProtection(); render(); refresh() }
    @objc func changeMinutes(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: "minutes"); render(); refresh() }
    @objc func testNotification() { notify("重置卡提醒已就绪", "临近到期时会在这里提醒你。", id: UUID().uuidString) }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            render()
        } catch { message = "登录启动设置失败：\(error.localizedDescription)"; render() }
    }
    @objc func chooseCodex() {
        popover.performClose(nil); NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.message = "选择 codex 可执行程序"
        if panel.runModal() == .OK, let url = panel.url { defaults.set(url.path, forKey: "codexPath"); refresh() }
    }
    @objc func help() {
        popover.performClose(nil); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Codex 重置卡助手"
        alert.informativeText = "平时每分钟检查；临近到期提高频率重试，多阶段提醒，默认前 60 分钟自动尝试使用。\n\n请先在终端运行 codex login，使用 ChatGPT 账号登录。\n\n自动使用要求应用运行、Mac 醒着并联网。唤醒后会补查，但已过期的卡无法恢复。服务端无可重置额度时会重试。\n\n通知权限可在系统设置 → 通知中开启。建议将应用放入 Applications 后开启登录时启动。"
        alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); network.cancel()
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

struct Dashboard: View {
    @ObservedObject var app: App
    private let accent = Color(red: 0.24, green: 0.43, blue: 0.92)
    private let green = Color(red: 0.14, green: 0.63, blue: 0.43)
    private var soonest: Card? { app.cards.first(where: { $0.status == "available" && ($0.expires ?? 0) > Date().timeIntervalSince1970 }) }
    func remaining(_ end: Double) -> String {
        let seconds = max(0, end - Date().timeIntervalSince1970)
        if seconds == 0 { return "已过期" }
        if seconds >= 86400 { return "\(Int(seconds / 86400)) 天 \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600)) 小时" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) 小时 \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) 分钟" }
        return "\(Int(ceil(seconds / 60))) 分钟"
    }
    func expiry(_ value: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 · HH:mm"
        return f.string(from: Date(timeIntervalSince1970: value))
    }
    func pill(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.10), in: Capsule())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重置卡助手")!)
                    .resizable().interpolation(.high).scaledToFit().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("重置卡助手").font(.system(size: 16, weight: .bold))
                    Text("CODEX · RESET CARDS").font(.system(size: 9, weight: .medium)).tracking(1.3).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium)).rotationEffect(.degrees(app.busy ? 180 : 0))
                        .frame(width: 30, height: 30).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(app.busy).help("立即刷新")
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            if app.showSettings {
                settingsPanel
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("可用重置卡").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(app.count.map(String.init) ?? "—").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text("张").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            if let card = soonest, let end = card.expires {
                                Text("最近到期 · \(expiry(end))").font(.system(size: 11)).foregroundStyle(.secondary)
                            } else { Text("额度补给，随时待命").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 12) {
                            pill(app.hasError ? "连接异常" : app.busy ? "同步中" : "已同步", color: app.hasError ? .orange : green)
                            Image(systemName: "rectangle.stack.fill").font(.system(size: 32)).foregroundStyle(accent.opacity(0.65))
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [accent.opacity(0.10), accent.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.13)))
                    HStack {
                        Text("我的卡片").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("按到期时间排序").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.padding(.top, 5).padding(.horizontal, 2)
                    if app.cards.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.stack").font(.system(size: 23)).foregroundStyle(.secondary)
                            Text(app.detailsKnown ? "暂无可用重置卡" : "正在等待卡片明细").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(22).cardSurface()
                    }
                    ForEach(Array(app.cards.enumerated()).dropFirst(safePage * 2).prefix(2), id: \.element.id) { index, card in
                        creditCard(card, index: index)
                    }
                    if app.cards.count > 2 {
                        HStack {
                            Button { app.cardPage = max(0, safePage - 1); app.objectWillChange.send() } label: { Image(systemName: "chevron.left") }.disabled(safePage == 0)
                            Spacer()
                            Text("第 \(safePage + 1) / \(pageCount) 页").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Button { app.cardPage = min(pageCount - 1, safePage + 1); app.objectWillChange.send() } label: { Image(systemName: "chevron.right") }.disabled(safePage == pageCount - 1)
                        }.buttonStyle(.borderless)
                    }
                    if let count = app.count, count > app.cards.count, app.detailsKnown {
                        Text("另有 \(count - app.cards.count) 张卡片尚未返回明细").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.shield.fill").font(.system(size: 18)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("自动重置").font(.system(size: 12, weight: .semibold))
                                Text(app.auto ? "在到期前自动尝试使用" : "已暂停自动使用").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("自动重置", isOn: Binding(get: { app.auto }, set: { _ in app.toggleAuto() })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(accent)
                        }
                        HStack(spacing: 6) {
                            Text("提前").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 4)
                            ForEach([10, 30, 60], id: \.self) { n in
                                Button { app.setMinutes(n) } label: {
                                    Text("\(n) 分钟").font(.system(size: 11, weight: Int(app.minutes) == n ? .semibold : .regular))
                                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                                        .foregroundStyle(Int(app.minutes) == n ? accent : Color.secondary)
                                        .background(Int(app.minutes) == n ? accent.opacity(0.11) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                        Text(app.notificationWarning == nil ? "多阶段提醒 · 临近到期提高频率重试" : "通知不可用，请在设置中检查授权").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(15).cardSurface()
                    if app.hasError || app.message != "已连接 Codex" && !app.busy {
                        Label(app.message, systemImage: app.hasError ? "exclamationmark.circle" : "info.circle")
                            .font(.system(size: 11)).foregroundStyle(app.hasError ? Color.orange : Color.secondary)
                            .lineLimit(2).help(app.message).padding(10).cardSurface()
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            HStack(spacing: 5) {
                Circle().fill(app.hasError ? Color.orange : green).frame(width: 5, height: 5)
                Text(app.lastRefresh.map { "更新于 " + $0.formatted(date: .omitted, time: .shortened) } ?? "正在连接…").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { app.showSettings.toggle(); app.objectWillChange.send() } label: { Image(systemName: app.showSettings ? "rectangle.stack" : "gearshape") }.help(app.showSettings ? "返回卡片" : "更多设置")
                Button { app.help() } label: { Image(systemName: "questionmark.circle") }.help("使用说明")
                Button { app.quit() } label: { Image(systemName: "power") }.help("退出")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 13)
                .background(Color.primary.opacity(0.025))
        }.frame(width: 380, height: 580).background(Color(nsColor: .windowBackgroundColor))
    }
    private var pageCount: Int { max(1, (app.cards.count + 1) / 2) }
    private var safePage: Int { min(app.cardPage, pageCount - 1) }
    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { app.showSettings = false; app.objectWillChange.send() } label: { Label("返回", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text("更多设置").font(.system(size: 13, weight: .semibold))
            }.padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 16) {
                Toggle("登录时启动", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { _ in app.toggleLogin() })).toggleStyle(.switch).controlSize(.small)
                Divider()
                Button("发送测试通知") { app.testNotification() }.buttonStyle(.borderless)
                Button("选择 Codex 程序…") { app.chooseCodex() }.buttonStyle(.borderless)
            }.font(.system(size: 12)).padding(16).cardSurface()
            VStack(alignment: .leading, spacing: 8) {
                Label("运行须知", systemImage: "info.circle").font(.system(size: 12, weight: .semibold))
                Text("到期前 24 小时、1 小时、10 分钟及 2 分钟提醒。临近到期提高频率重试并阻止空闲睡眠，合盖或关机仍无法运行。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).cardSurface()
            if let last = app.defaults.string(forKey: "lastOutcome") {
                Label(last, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).padding(14).cardSurface()
            }
            if let warning = app.notificationWarning { Label(warning, systemImage: "bell.slash").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).padding(12).cardSurface() }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.bottom, 16)
    }
    func creditCard(_ card: Card, index: Int) -> some View {
        let urgent = card.expires.map { $0 - Date().timeIntervalSince1970 < 3600 } ?? false
        let tint: Color = urgent ? .orange : accent
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ticket.fill").font(.system(size: 18)).foregroundStyle(tint)
                .frame(width: 38, height: 38).background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("额度重置卡 \(String(format: "%02d", index + 1))").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    pill(card.status == "available" ? "可用" : card.status, color: card.status == "available" ? green : .secondary)
                }
                if let end = card.expires {
                    Text("剩余 " + remaining(end)).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(urgent ? Color.orange : Color.primary)
                    Text(expiry(end) + " 到期").font(.system(size: 10)).foregroundStyle(.secondary)
                } else { Text("无到期时间").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }.padding(12).cardSurface()
    }
}
extension View {
    func cardSurface() -> some View {
        self.background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.primary.opacity(0.055)))
    }
}
signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--monitor-tests") {
    do { try runMonitorTests() } catch { print("FAIL:", error); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    let now = 10000.0
    func card(_ status: String, _ expires: Any, _ type: String = "codexRateLimits") -> Card { Card(["id": "test", "status": status, "expiresAt": expires, "resetType": type])! }
    precondition(card("available", now + 600).due(now, minutes: 10))
    precondition(!card("available", now + 601).due(now, minutes: 10))
    precondition(!card("available", now).due(now, minutes: 10))
    precondition(!card("available", now - 1).due(now, minutes: 10))
    precondition(!card("redeemed", now + 10).due(now, minutes: 10))
    precondition(!card("available", NSNull()).due(now, minutes: 10))
    precondition(!card("available", now + 10, "other").due(now, minutes: 10))
    print("PASS: expiry boundary, expired, status, missing expiry, reset type")
 } else if CommandLine.arguments.contains("--health-check") {
    let center = UNUserNotificationCenter.current()
    let wait = DispatchSemaphore(value: 0)
    center.getNotificationSettings { settings in
        print("Notification authorization:", settings.authorizationStatus.rawValue, "banner:", settings.alertSetting.rawValue)
        center.getPendingNotificationRequests { requests in
            print("Pending expiry reminders:", requests.filter { $0.identifier.hasPrefix("expiry.") }.count)
            wait.signal()
        }
    }
    if wait.wait(timeout: .now() + 10) == .timedOut { print("Notification health check timed out"); exit(1) }
    print("Auto reset:", UserDefaults.standard.object(forKey: "auto") as? Bool ?? true, "minutes:", UserDefaults.standard.double(forKey: "minutes"))
} else if CommandLine.arguments.contains("--check-account") {
    do {
        let path = CommandLine.arguments.dropFirst(2).first ?? "/opt/homebrew/bin/codex"
        let rpc = try RPC(path: path); defer { rpc.close() }
        let result = try rpc.call("account/rateLimits/read")
        let summary = result["rateLimitResetCredits"] as? [String: Any]
        print("Read-only account check: availableCount=\(summary?["availableCount"] ?? "unknown")")
        let rows = summary?["credits"] as? [[String: Any]] ?? []
        for card in rows.compactMap(Card.init) {
            print("status=\(card.status), expiresAt=\(card.expires.map(String.init(describing:)) ?? "null")")
        }
    } catch { print(error.localizedDescription); exit(1) }
} else {
    signal(SIGPIPE, SIG_IGN)
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ResetCardBar")
    do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { print(error); exit(1) }
    let lockFD = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { print("ResetCardBar is already running or instance lock unavailable"); exit(0) }
    let app = NSApplication.shared
    let delegate = App(); app.delegate = delegate
    app.setActivationPolicy(.accessory); app.run()
}
