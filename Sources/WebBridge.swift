import Foundation
import UIKit
import WebKit
import AudioToolbox
import UserNotifications

/// JavaScript bridge. WKWebView has no synchronous JS→native calls, so the page talks to us
/// through `window.prompt("__oc__{json}")`, which WKUIDelegate answers synchronously. Async work
/// (HTTP, SSE, WebSocket, Zen streaming) reports back through `window.OCEvent(name, payload)`.
final class WebBridge: NSObject, WKUIDelegate {
    weak var webView: WKWebView?

    private let config = ServerConfig.shared
    private let stateLock = NSLock()

    private lazy var network: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 3600
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "OpenCode-Mobile-iOS"]
        return URLSession(configuration: c)
    }()

    private lazy var probeSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    private var httpTasks: [String: URLSessionDataTask] = [:]
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var sseTask: Task<Void, Never>?
    private var sseGeneration = 0
    private var cachedConfigText = "{}"
    private var cachedConfig: [String: Any] = [:]
    private var serverVersion = ""
    private var connected = false
    private var logLines: [String] = []
    private var lastNotification = Date.distantPast
    private var notificationsRequested = false
    private let agent = AgentEngine.shared
    private let shell = ShellRunner.shared
    private var terminalID: String?
    private var terminalCwd = AgentPaths.workspace.path
    private var terminalBuffer = ""
    private var terminalBusy = false

    // MARK: - prompt bridge

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard prompt.hasPrefix("__oc__"),
              let data = prompt.dropFirst(6).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String else {
            completionHandler(nil)
            return
        }
        let args = obj["args"] as? [Any] ?? []
        completionHandler(handle(op: op, args: args))
    }

    private func handle(op: String, args: [Any]) -> String? {
        switch op {
        case "state":
            return stateJSON()
        case "serverInfo":
            return jsonString([
                "url": config.serverURL,
                "version": serverVersion,
                "connected": connected,
                "hasPassword": !config.password.isEmpty
            ])
        case "http":
            guard args.count >= 4,
                  let id = args[0] as? String,
                  let method = args[1] as? String,
                  let path = args[2] as? String else { return nil }
            let body = args[3] as? String ?? ""
            let (status, obj) = agent.handle(method: method.uppercased(), path: path, body: body)
            let text: String
            if let obj { text = anyJSON(obj) } else { text = "" }
            emit("http", ["id": id, "status": status, "ct": "application/json", "body": text])
            return nil
        case "drop":
            return nil
        case "sseStart":
            agent.startEvents()
            return nil
        case "sseStop":
            return nil
        case "wsOpen":
            guard args.count >= 2, let id = args[0] as? String else { return nil }
            openLocalTerminal(id: id)
            return nil
        case "wsSend":
            guard args.count >= 2, let id = args[0] as? String, let text = args[1] as? String else { return nil }
            if id == terminalID { terminalInput(text) }
            return nil
        case "wsClose":
            if let id = args.first as? String { closeLocalTerminal(id: id) }
            return nil
        case "ls":
            if let path = args.first as? String { return localLS(path) }
            return jsonString(["ok": false, "err": "Нет пути"])
        case "fs":
            guard args.count >= 3, let op = args[0] as? String, let path = args[1] as? String else {
                return jsonString(["ok": false, "err": "Некорректный вызов"])
            }
            return localFS(op: op, path: path, arg: args[2] as? String ?? "")
        case "readText":
            if let path = args.first as? String { return localReadText(path) }
            return jsonString(["ok": false, "err": "Нет пути"])
        case "writeText":
            if args.count >= 2, let path = args[0] as? String, let text = args[1] as? String {
                return localWriteText(path, text)
            }
            return jsonString(["ok": false, "err": "Некорректный вызов"])
        case "cfgRead":
            let cfg = AgentPaths.userConfigFile
            return (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
        case "cfgWrite":
            if let text = args.first as? String { return localWriteConfig(text) }
            return jsonString(["ok": false, "err": "Нет текста конфигурации"])
        case "readLog":
            return "OpenCode iOS · локальный режим\nWorkspace: \(AgentPaths.workspace.path)\nМодель: \(ServerConfig.shared.zenModel)\nКоманды: ios_system"
        case "connect", "connectSaved", "disconnect":
            return nil
        case "restartServer":
            toast("Локальный агент работает на устройстве — перезапуск не нужен")
            return nil
        case "copy":
            if let text = args.first as? String { UIPasteboard.general.string = text }
            return nil
        case "pasteText":
            return UIPasteboard.general.string ?? ""
        case "share":
            if let text = args.first as? String { presentShare(text) }
            return nil
        case "openLink":
            if let s = args.first as? String, let url = URL(string: s) {
                DispatchQueue.main.async { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            }
            return nil
        case "grant":
            if let kind = args.first as? String, kind == "notifications" { requestNotifications() }
            return nil
        case "setFlag":
            if args.count >= 2, let key = args[0] as? String, let value = args[1] as? Bool {
                UserDefaults.standard.set(value, forKey: "ocm.flag." + key)
            }
            return nil
        case "testSound":
            AudioServicesPlaySystemSound(1057)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return nil
        case "minimize":
            DispatchQueue.main.async { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            return nil
        case "install", "resetInstall", "start":
            emit("ready", [:])
            return nil
        case "pickFile":
            emit("picked", ["ok": false, "error": "Загрузка файлов доступна на компьютере, где запущен opencode"])
            return nil
        case "authLogin":
            ZenClient.shared.startDeviceLogin()
            return nil
        case "authCancel":
            ZenClient.shared.cancelLogin()
            return nil
        case "authLogout":
            ZenClient.shared.logout()
            emit("authlogout", ["ok": true])
            return nil
        case "signInGuest":
            emit("signin", ["ok": true, "guest": true])
            return nil
        case "signIn", "signInEmail", "signOut":
            emit("signin", ["ok": false, "error": "Вход выполняется в Настройках → Аккаунт opencode"])
            return nil
        case "checkUpdates":
            emit("update", ["error": "Обновления приложения выходят в GitHub Releases. Установите новую версию через AltStore/Sideloadly."])
            return nil
        case "applyAppUpdate", "applyCoreUpdate":
            emit("update", ["error": "Обновления устанавливаются через GitHub Releases"])
            return nil
        default:
            return nil
        }
    }

    // MARK: - state

    private func stateJSON() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let flags: [String: Any] = [
            "snd_done": UserDefaults.standard.object(forKey: "ocm.flag.snd_done") as? Bool ?? true,
            "snd_action": UserDefaults.standard.object(forKey: "ocm.flag.snd_action") as? Bool ?? true,
            "snd_quota": UserDefaults.standard.object(forKey: "ocm.flag.snd_quota") as? Bool ?? true,
            "noseccomp": false
        ]
        let notifications = UserDefaults.standard.bool(forKey: "ocm.notifications")
        let perms: [String: Any] = ["notifications": notifications, "files": true, "install": true, "battery": true]
        let dict: [String: Any] = [
            "version": version,
            "code": Int(build) ?? 1,
            "user": ZenClient.shared.accountEmail ?? "Локальный режим",
            "name": "OpenCode iPhone",
            "guest": ZenClient.shared.accountEmail == nil,
            "googleConfigured": false,
            "installed": true,
            "core": "on-device",
            "perms": perms,
            "flags": flags,
            "ready": true,
            "server": AgentPaths.workspace.path,
            "hasPassword": false,
            "connected": true,
            "ios": true,
            "local": true
        ]
        return jsonString(dict)
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - server connection

    private func probe(_ base: String, password: String) async -> (Bool, String, String) {
        guard let url = URL(string: base + "/global/health") else {
            return (false, "Некорректный URL", "")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        if !password.isEmpty {
            req.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await probeSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (false, "Нет ответа сервера", "") }
            if http.statusCode == 401 { return (false, "Неверный пароль сервера", "") }
            if (200..<300).contains(http.statusCode) {
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let version = obj?["version"] as? String ?? ""
                return (true, "", version)
            }
            return (false, "Сервер ответил HTTP \(http.statusCode)", "")
        } catch {
            return (false, friendlyNetworkError(error), "")
        }
    }

    private func friendlyNetworkError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "Не удалось подключиться. Проверьте адрес и что opencode serve запущен с --hostname 0.0.0.0"
            case NSURLErrorTimedOut:
                return "Сервер не ответил вовремя. Проверьте адрес, порт и firewall."
            case NSURLErrorNotConnectedToInternet:
                return "Нет подключения к интернету."
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "iOS заблокировала HTTP. Используйте HTTPS или локальную сеть."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func connect(url raw: String, password: String?, persist: Bool, emitEvent: Bool) {
        guard let normalized = ServerConfig.normalize(raw) else {
            if emitEvent { emit("connect", ["ok": false, "error": "Введите адрес сервера, например http://192.168.1.10:4096"]) }
            return
        }
        let pw = password ?? config.password
        Task { [weak self] in
            guard let self else { return }
            let (ok, error, version) = await self.probe(normalized, password: pw)
            DispatchQueue.main.async {
                if ok {
                    self.config.serverURL = normalized
                    if let password, persist { self.config.password = password }
                    self.serverVersion = version
                    self.connected = true
                    self.log("connected to \(normalized) (\(version))")
                    self.refreshConfigCache()
                    self.requestNotifications()
                    if emitEvent {
                        self.emit("connect", ["ok": true, "version": version, "url": normalized])
                    }
                    self.emit("server", ["ready": true])
                } else {
                    self.connected = false
                    self.log("connect failed: \(error)")
                    if emitEvent { self.emit("connect", ["ok": false, "error": error]) }
                    self.emit("server", ["ready": false])
                }
            }
        }
    }

    private func disconnect() {
        stopSSE()
        stateLock.lock()
        sockets.values.forEach { $0.cancel(with: .goingAway, reason: nil) }
        sockets.removeAll()
        httpTasks.values.forEach { $0.cancel() }
        httpTasks.removeAll()
        stateLock.unlock()
        connected = false
        emit("server", ["ready": false])
    }

    private func restartServer() {
        guard let url = config.apiURL("/instance/dispose") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        network.dataTask(with: req) { [weak self] _, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                self.toast("Сервер перезапущен")
                self.stopSSE()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.startSSE() }
            } else {
                self.toast("Сервер не перезапустился (HTTP \(code))")
            }
        }.resume()
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        stateLock.lock()
        logLines.append(stamp + "  " + line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        stateLock.unlock()
    }

    // MARK: - config cache (GET/PATCH /config)

    private func refreshConfigCache() {
        guard let url = config.apiURL("/config") else { return }
        var req = URLRequest(url: url)
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        network.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = String(data: data, encoding: .utf8) else { return }
            self.stateLock.lock()
            self.cachedConfig = obj
            self.cachedConfigText = text
            self.stateLock.unlock()
        }.resume()
    }

    private func writeConfig(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return jsonString(["ok": false, "err": "Неверный JSON"])
        }
        stateLock.lock()
        cachedConfig = obj
        cachedConfigText = text
        stateLock.unlock()

        guard let url = config.apiURL("/config") else {
            return jsonString(["ok": false, "err": "Сервер не настроен"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        network.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            if let error {
                self.toast("Конфигурация не сохранена: \(error.localizedDescription)")
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                self.toast("Конфигурация сохранена")
            } else {
                self.toast("Конфигурация не сохранена (HTTP \(code))")
            }
        }.resume()
        return jsonString(["ok": true])
    }

    // MARK: - HTTP

    private func performHTTP(id: String, method: String, path: String, body: String) {
        guard let url = config.apiURL(path) else {
            emit("http", ["id": id, "err": "Сначала подключитесь к серверу OpenCode"])
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        if ["POST", "PUT", "PATCH"].contains(method) {
            req.httpBody = Data((body.isEmpty ? "{}" : body).utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let task = network.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            stateLock.lock(); httpTasks.removeValue(forKey: id); stateLock.unlock()
            if let error {
                self.emit("http", ["id": id, "err": error.localizedDescription])
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let ct = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let text = String(decoding: data ?? Data(), as: UTF8.self)
            self.emit("http", ["id": id, "status": status, "ct": ct, "body": text])
        }
        stateLock.lock(); httpTasks[id] = task; stateLock.unlock()
        task.resume()
    }

    // MARK: - SSE

    private func startSSE() {
        stopSSE()
        sseGeneration += 1
        let gen = sseGeneration
        guard let url = config.apiURL("/global/event") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        let session = network

        sseTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && gen == self.sseGeneration {
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    self.emit("sse", ["t": "open"])
                    for try await line in bytes.lines {
                        if Task.isCancelled || gen != self.sseGeneration { break }
                        if line.hasPrefix("data:") {
                            let d = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if !d.isEmpty {
                                self.emit("sse", ["t": "data", "d": d])
                                self.inspectEvent(d)
                            }
                        }
                    }
                } catch {
                    self.log("sse: \(error.localizedDescription)")
                }
                if Task.isCancelled || gen != self.sseGeneration { break }
                self.emit("sse", ["t": "close"])
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func stopSSE() {
        sseGeneration += 1
        sseTask?.cancel()
        sseTask = nil
    }

    private func inspectEvent(_ raw: String) {
        guard raw.count < 2_000_000,
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let obj = (root["payload"] as? [String: Any]) ?? root
        let type = obj["type"] as? String ?? ""
        let now = Date()
        guard now.timeIntervalSince(lastNotification) > 3 else { return }

        func notify(_ title: String, _ body: String, _ sound: Bool) {
            lastNotification = now
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            guard UserDefaults.standard.bool(forKey: "ocm.notifications") else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }

        if type == "session.idle" {
            notify("Задача завершена", "OpenCode закончил работу.", true)
        } else if type == "question.asked" || type.hasPrefix("permission.") {
            notify("Требуется действие", "OpenCode ждёт вашего ответа или подтверждения.", true)
        } else if type == "session.error" {
            let text = String(describing: obj).lowercased()
            if text.contains("quota") || text.contains("rate limit") || text.contains("429") {
                notify("Квота исчерпана", "Лимит модели исчерпан. Смените модель или подключите свой ключ.", true)
            }
        }
    }

    // MARK: - WebSocket / PTY

    private func webSocketURL(_ path: String) -> URL? {
        guard var c = URLComponents(string: config.serverURL + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return c.url
    }

    private func openSocket(id: String, path: String) {
        closeSocket(id: id)
        guard let url = webSocketURL(path) else {
            emit("ws", ["id": id, "t": "err", "d": "bad url"])
            return
        }
        var req = URLRequest(url: url)
        if let auth = config.basicAuth { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        let task = network.webSocketTask(with: req)
        stateLock.lock(); sockets[id] = task; stateLock.unlock()
        task.resume()
        emit("ws", ["id": id, "t": "open"])
        receiveSocket(id: id, task: task)
    }

    private func receiveSocket(id: String, task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.emit("ws", ["id": id, "t": "msg", "d": text])
                self.receiveSocket(id: id, task: task)
            case .success(.data(let data)):
                if data.first != 0 {
                    self.emit("ws", ["id": id, "t": "bin", "d": data.base64EncodedString()])
                }
                self.receiveSocket(id: id, task: task)
            case .failure(let error):
                self.emit("ws", ["id": id, "t": "err", "d": error.localizedDescription])
                self.closeSocket(id: id)
            @unknown default:
                self.closeSocket(id: id)
            }
        }
    }

    private func sendSocket(id: String, text: String) {
        stateLock.lock(); let task = sockets[id]; stateLock.unlock()
        task?.send(.string(text)) { _ in }
    }

    private func closeSocket(id: String) {
        stateLock.lock(); let task = sockets.removeValue(forKey: id); stateLock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - notifications / UI helpers

    private func requestNotifications() {
        guard !notificationsRequested else { return }
        notificationsRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            UserDefaults.standard.set(granted, forKey: "ocm.notifications")
            self?.log("notifications granted: \(granted)")
        }
    }

    private func toast(_ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              var s = String(data: data, encoding: .utf8) else { return }
        s.removeFirst(); s.removeLast()
        let js = "window.OCM && OCM.toast(\(s), 4000);"
        DispatchQueue.main.async { [weak self] in self?.webView?.evaluateJavaScript(js, completionHandler: nil) }
    }

    private func presentShare(_ text: String) {
        DispatchQueue.main.async {
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController else { return }
            var top = root
            while let presented = top.presentedViewController { top = presented }
            let vc = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            if let pop = vc.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            }
            top.present(vc, animated: true)
        }
    }

    func emitSSE(_ json: String) {
        emit("sse", ["t": "data", "d": json])
    }

    // MARK: - local terminal (ios_system)

    private func ws(_ id: String, _ type: String, _ data: String? = nil) {
        var payload: [String: Any] = ["id": id, "t": type]
        if let data { payload["d"] = data }
        emit("ws", payload)
    }

    private func promptText() -> String {
        let rel = AgentPaths.relative(URL(fileURLWithPath: terminalCwd))
        return "opencode:\(rel.isEmpty ? "/" : "/" + rel)$ "
    }

    private func openLocalTerminal(id: String) {
        terminalID = id
        terminalBuffer = ""
        terminalCwd = AgentPaths.workspace.path
        ws(id, "open")
        let welcome = "OpenCode shell · ios_system\r\nWorkspace: \(AgentPaths.workspace.path)\r\nВведите help для списка команд. exit — закрыть сессию.\r\n\r\n" + promptText()
        ws(id, "msg", welcome)
    }

    private func closeLocalTerminal(id: String) {
        if terminalID == id { terminalID = nil }
        ws(id, "close")
    }

    private func terminalInput(_ text: String) {
        guard let id = terminalID else { return }
        for ch in text {
            if ch == "\r" || ch == "\n" {
                ws(id, "msg", "\r\n")
                let cmd = terminalBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                terminalBuffer = ""
                if cmd.isEmpty { ws(id, "msg", promptText()); continue }
                if cmd == "exit" { ws(id, "msg", "logout\r\n"); closeLocalTerminal(id: id); continue }
                if cmd == "clear" { ws(id, "msg", "\u{001B}[2J\u{001B}[H" + promptText()); continue }
                if cmd == "help" {
                    ws(id, "msg", "Доступно: ls, cat, cd, pwd, echo, grep, sed, awk, find, sort, uniq, wc, diff, cp, mv, rm, mkdir, touch, chmod, tar, gzip, date, env, xargs, git (init/status/add/commit/log/diff/branch/checkout).\r\nНет node, npm и компиляторов. Python — beta.\r\n" + promptText())
                    continue
                }
                if cmd == "pwd" { ws(id, "msg", terminalCwd + "\r\n" + promptText()); continue }
                if cmd.hasPrefix("cd ") {
                    let target = String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    if let newDir = AgentPaths.resolve(target.hasPrefix("/") ? target : terminalCwd + "/" + target) {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: newDir.path, isDirectory: &isDir), isDir.boolValue {
                            terminalCwd = newDir.path
                            ws(id, "msg", promptText())
                        } else {
                            ws(id, "msg", "cd: no such directory\r\n" + promptText())
                        }
                    } else {
                        ws(id, "msg", "cd: outside workspace\r\n" + promptText())
                    }
                    continue
                }
                terminalBusy = true
                shell.runAsync(cmd, cwd: terminalCwd, timeout: 120) { [weak self] code, output in
                    guard let self, self.terminalID == id else { return }
                    var out = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
                    if !out.isEmpty && !out.hasSuffix("\r\n") { out += "\r\n" }
                    if !out.isEmpty { self.ws(id, "msg", out) }
                    if code != 0 { self.ws(id, "msg", "[код \(code)]\r\n") }
                    self.terminalBusy = false
                    self.ws(id, "msg", self.promptText())
                }
            } else if ch == "\u{7F}" || ch == "\u{8}" {
                if !terminalBuffer.isEmpty {
                    terminalBuffer.removeLast()
                    ws(id, "msg", "\u{8} \u{8}")
                }
            } else if ch == "\u{3}" {
                terminalBuffer = ""
                if terminalBusy { shell.kill() }
                ws(id, "msg", "^C\r\n" + promptText())
            } else if ch == "\t" {
                terminalBuffer += "  "
                ws(id, "msg", "  ")
            } else if ch.unicodeScalars.first.map({ $0.value >= 32 }) == true {
                if terminalBuffer.count < 4000 {
                    terminalBuffer.append(ch)
                    ws(id, "msg", String(ch))
                }
            }
        }
    }

    func emitAuth(_ payload: [String: Any]) {
        emit("authlogin", payload)
    }

    private func anyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func localLS(_ path: String) -> String {
        guard let dir = AgentPaths.resolve(path) else {
            return jsonString(["ok": false, "err": "Путь вне рабочей папки"])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return jsonString(["ok": false, "err": "Папка не найдена"])
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: [])) ?? []
        let items: [[String: Any]] = urls.map { url in
            let d = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return ["name": url.lastPathComponent, "dir": d]
        }.sorted {
            let a = $0["dir"] as? Bool ?? false
            let b = $1["dir"] as? Bool ?? false
            if a != b { return a && !b }
            return ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending
        }
        return jsonString(["ok": true, "path": path, "items": items])
    }

    private func localFS(op: String, path: String, arg: String) -> String {
        guard let url = AgentPaths.resolve(path) else {
            return jsonString(["ok": false, "err": "Путь вне рабочей папки"])
        }
        let fm = FileManager.default
        do {
            switch op {
            case "mkdir":
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case "create":
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: Data()) }
            case "delete":
                try fm.removeItem(at: url)
            case "rename":
                let dst: URL
                if arg.contains("/") {
                    guard let resolved = AgentPaths.resolve(arg) else {
                        return jsonString(["ok": false, "err": "Некорректное имя"])
                    }
                    dst = resolved
                } else {
                    dst = url.deletingLastPathComponent().appendingPathComponent(arg)
                }
                try fm.moveItem(at: url, to: dst)
            default:
                return jsonString(["ok": false, "err": "Неизвестная операция \(op)"])
            }
            return jsonString(["ok": true])
        } catch {
            return jsonString(["ok": false, "err": shortError(error)])
        }
    }

    private func localReadText(_ path: String) -> String {
        guard let url = AgentPaths.resolve(path), FileManager.default.fileExists(atPath: url.path) else {
            return jsonString(["ok": false, "err": "Файл не найден"])
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size < 2_000_000, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return jsonString(["ok": false, "err": "Файл слишком большой или бинарный"])
        }
        return jsonString(["ok": true, "text": text])
    }

    private func localWriteText(_ path: String, _ text: String) -> String {
        guard let url = AgentPaths.resolve(path) else {
            return jsonString(["ok": false, "err": "Путь вне рабочей папки"])
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return jsonString(["ok": true])
        } catch {
            return jsonString(["ok": false, "err": shortError(error)])
        }
    }

    private func localWriteConfig(_ text: String) -> String {
        guard let data = stripJSONC(text).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            return jsonString(["ok": false, "err": "Неверный JSON"])
        }
        do {
            try text.write(to: AgentPaths.userConfigFile, atomically: true, encoding: .utf8)
            AgentEngine.shared.reloadConfig()
            return jsonString(["ok": true])
        } catch {
            return jsonString(["ok": false, "err": shortError(error)])
        }
    }

    private func emit(_ name: String, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.OCEvent && window.OCEvent(\"\(name)\", \(json));"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}