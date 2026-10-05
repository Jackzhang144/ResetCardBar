import AppKit
import Sparkle

// Keep archive verification and installation in Sparkle; never execute a downloaded shell script.
enum UpdatePolicy {
    static func mayRestart(busy: Bool, auto: Bool, cards: [Card], now: Double) -> Bool {
        !busy && !(auto && cards.contains { $0.due(now, minutes: 2) })
    }
}

extension App: SPUUpdaterDelegate {
    func startUpdates() {
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        updaterController?.startUpdater()
        if let updater = updaterController?.updater, updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
        updateObservation = updaterController?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }
    @objc func checkForUpdates() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(nil)
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateMessage = "发现新版本 " + item.displayVersionString
        objectWillChange.send()
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        updateMessage = "已是最新版本"; objectWillChange.send()
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        updateRestartPending = false
        updateMessage = (error as NSError).domain == SUSparkleErrorDomain && (error as NSError).code == 1001 ? "已是最新版本" : "更新未完成：" + error.localizedDescription
        refresh()
        objectWillChange.send()
    }
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard updater.automaticallyDownloadsUpdates else { return false }
        updateMessage = "更新已下载，等待安全重启"; objectWillChange.send()
        waitForSafeUpdate(immediateInstallationBlock)
        return true
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock: @escaping () -> Void) -> Bool {
        guard !UpdatePolicy.mayRestart(busy: busy || loginSession != nil, auto: auto, cards: cards, now: Date().timeIntervalSince1970) else { return false }
        waitForSafeUpdate(untilInvokingBlock)
        return true
    }
    func waitForSafeUpdate(_ install: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if !UpdatePolicy.mayRestart(busy: self.busy || self.loginSession != nil, auto: self.auto, cards: self.cards, now: Date().timeIntervalSince1970) {
                self.waitForSafeUpdate(install); return
            }
            self.updateRestartPending = true
            self.timer?.invalidate()
            self.updateMessage = "正在安装更新并重启…"; self.objectWillChange.send()
            install()
        }
    }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        updateRestartPending = true; timer?.invalidate()
    }
}
