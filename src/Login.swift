import AppKit

final class LoginSession {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
extension App {
    func cancelLogin() { loginSession?.cancel(); loginMessage = "正在取消登录…"; objectWillChange.send() }
    func login() {
        guard loginSession == nil else { return }
        let session = LoginSession(); loginSession = session
        loginMessage = "正在打开浏览器登录…"; objectWillChange.send()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var resultMessage = "登录已取消"
            do {
                let rpc = try RPC(path: executable()); defer { rpc.close() }
                let result = try rpc.call("account/login/start", ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"])
                guard let text = result["authUrl"] as? String, let url = URL(string: text), url.scheme == "https",
                      let host = url.host, host == "chatgpt.com" || host.hasSuffix(".openai.com") else {
                    throw Failure(message: "登录接口未返回有效的官方浏览器地址")
                }
                DispatchQueue.main.async {
                    if !session.isCancelled { NSWorkspace.shared.open(url); self.loginMessage = "请在浏览器完成登录，最多等待 5 分钟"; self.objectWillChange.send() }
                }
                let deadline = Date().addingTimeInterval(300)
                while !session.isCancelled && Date() < deadline {
                    if let completion = rpc.takeLoginCompletion() {
                        guard completion["success"] as? Bool == true else { throw Failure(message: completion["error"] as? String ?? "登录未完成") }
                        resultMessage = "登录成功，正在刷新卡片"; break
                    }
                    if !rpc.process.isRunning { throw Failure(message: "登录服务已退出，请重试") }
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if !session.isCancelled && Date() >= deadline { resultMessage = "登录超时，请重试" }
            } catch { resultMessage = "登录失败：" + error.localizedDescription }
            DispatchQueue.main.async {
                self.loginSession = nil; self.loginMessage = resultMessage; self.objectWillChange.send(); self.refresh()
            }
        }
    }
}
