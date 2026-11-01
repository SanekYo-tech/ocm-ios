import Foundation

enum AgentPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Everything the agent can touch lives here. The app's Documents directory is
    /// exposed in the Files app as the "OpenCode" folder, so the path is simply
    /// On My iPhone → OpenCode → config.json / your project.
    static var workspace: URL {
        documents
    }

    static var configDir: URL {
        workspace.appendingPathComponent(".opencode", isDirectory: true)
    }

    static var configFile: URL {
        configDir.appendingPathComponent("opencode.json")
    }

    /// User-editable OpenCode config, visible in the Files app at the workspace root.
    static var userConfigFile: URL {
        workspace.appendingPathComponent("config.json")
    }

    static var stateDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenCodeAgent", isDirectory: true)
    }

    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stateDir, withIntermediateDirectories: true)

        let config = workspace.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: config.path),
           let template = Bundle.main.url(forResource: "default-config", withExtension: "json"),
           let data = try? Data(contentsOf: template) {
            try? data.write(to: config, options: .atomic)
        }

        let agents = workspace.appendingPathComponent("AGENTS.md")
        if !fm.fileExists(atPath: agents.path) {
            let rules = """
            # Правила для агента

            - Работай только внутри папки OpenCode.
            - Сначала прочитай relevant files, потом меняй.
            - Не запускай node/npm/python/git — их нет на iOS.
            - Для команд используй встроенный Unix-shell (ls, cat, grep, sed, awk, find, diff, tar).
            - Отвечай на языке пользователя.
            """
            try? rules.write(to: agents, atomically: true, encoding: .utf8)
        }

        let readme = workspace.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            # OpenCode на iPhone

            Это рабочая папка агента. Она видна в приложении «Файлы» → «На iPhone» → «OpenCode».

            - Кладите сюда проекты и файлы.
            - Агент читает и редактирует их прямо на устройстве.
            - Папка `.opencode` хранит конфигурацию.

            Ограничение iOS: приложение не запускает shell-команды и сторонние бинарники.
            Вместо этого агент использует встроенные инструменты чтения, записи, поиска и веб-загрузки.
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Maps paths coming from the UI (`/root/...`, `/sdcard/...`, absolute workspace paths,
    /// relative paths) into the workspace and rejects escapes.
    static func resolve(_ raw: String) -> URL? {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || p == "." || p == "/" || p == "/root" { return workspace }

        let ws = workspace.standardizedFileURL.path
        if p == ws { return workspace }
        if p.hasPrefix(ws + "/") {
            return URL(fileURLWithPath: p).standardizedFileURL
        }
        if p.hasPrefix("/root/.config/opencode") {
            p = ".opencode" + String(p.dropFirst("/root/.config/opencode".count))
        }
        else if p.hasPrefix("/root/") { p = String(p.dropFirst("/root".count)) }
        else if p.hasPrefix("/sdcard/") { p = String(p.dropFirst("/sdcard".count)) }
        else if p.hasPrefix("/storage/emulated/0/") { p = String(p.dropFirst("/storage/emulated/0".count)) }
        if p.hasPrefix("/") { p.removeFirst() }

        let url = workspace.appendingPathComponent(p).standardizedFileURL
        let root = workspace.standardizedFileURL.path
        guard url.path == root || url.path.hasPrefix(root + "/") else { return nil }
        return url
    }

    static func relative(_ url: URL) -> String {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func newID(_ prefix: String) -> String {
    let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    return prefix + raw.prefix(26)
}

func jsonText(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

func shortError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "Нет подключения к интернету"
        case NSURLErrorTimedOut: return "Сервер не ответил вовремя"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Не удалось подключиться к серверу"
        default: break
        }
    }
    return error.localizedDescription
}

/// Thread-safe JSON-backed session store.
final class AgentStore {
    static let shared = AgentStore()

    private let lock = NSRecursiveLock()
    private var sessions: [[String: Any]] = []
    private var messages: [String: [[String: Any]]] = [:]
    private var todos: [String: [[String: Any]]] = [:]
    private var diffs: [String: [[String: Any]]] = [:]
    private var statuses: [String: String] = [:]
    private var reverted: [String: [[String: Any]]] = [:]
    private let fileURL: URL

    private init() {
        AgentPaths.prepare()
        fileURL = AgentPaths.stateDir.appendingPathComponent("sessions.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        sessions = obj["sessions"] as? [[String: Any]] ?? []
        messages = obj["messages"] as? [String: [[String: Any]]] ?? [:]
        todos = obj["todos"] as? [String: [[String: Any]]] ?? [:]
        diffs = obj["diffs"] as? [String: [[String: Any]]] ?? [:]
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        let obj: [String: Any] = [
            "sessions": sessions,
            "messages": messages,
            "todos": todos,
            "diffs": diffs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func allSessions() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return sessions.sorted {
            let a = (($0["time"] as? [String: Any])?["updated"] as? NSNumber)?.int64Value ?? 0
            let b = (($1["time"] as? [String: Any])?["updated"] as? NSNumber)?.int64Value ?? 0
            return a > b
        }
    }

    @discardableResult
    func createSession(title: String = "Новая сессия", parentID: String? = nil) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let t = nowMs()
        var s: [String: Any] = [
            "id": newID("ses_"),
            "title": title,
            "time": ["created": t, "updated": t],
            "directory": AgentPaths.workspace.path
        ]
        if let parentID { s["parentID"] = parentID }
        sessions.append(s)
        messages[s["id"] as! String] = []
        statuses[s["id"] as! String] = "idle"
        return s
    }

    func session(_ id: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return sessions.first { ($0["id"] as? String) == id }
    }

    func updateSession(_ id: String, title: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let i = sessions.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        if let title, !title.isEmpty { sessions[i]["title"] = title }
        var time = sessions[i]["time"] as? [String: Any] ?? [:]
        time["updated"] = nowMs()
        sessions[i]["time"] = time
    }

    func deleteSession(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll { ($0["id"] as? String) == id }
        messages[id] = nil
        todos[id] = nil
        diffs[id] = nil
        statuses[id] = nil
        reverted[id] = nil
    }

    func setStatus(_ id: String, _ status: String) {
        lock.lock(); defer { lock.unlock() }
        statuses[id] = status
    }

    func status(_ id: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return statuses[id] ?? "idle"
    }

    func statusesSnapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return statuses
    }

    func allMessages(_ sid: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return messages[sid] ?? []
    }

    func appendMessage(_ sid: String, _ message: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        var list = messages[sid] ?? []
        if let id = (message["info"] as? [String: Any])?["id"] as? String {
            list.removeAll { (($0["info"] as? [String: Any])?["id"] as? String) == id }
        }
        list.append(message)
        messages[sid] = list
    }

    func updateMessage(_ sid: String, _ mid: String, info: [String: Any]? = nil, part: [String: Any]? = nil, removePart: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var list = messages[sid] ?? []
        guard let i = list.firstIndex(where: { (($0["info"] as? [String: Any])?["id"] as? String) == mid }) else { return }
        if let info { list[i]["info"] = info }
        if var parts = list[i]["parts"] as? [[String: Any]] {
            if let part {
                if let pi = parts.firstIndex(where: { ($0["id"] as? String) == (part["id"] as? String) }) {
                    parts[pi] = part
                } else {
                    parts.append(part)
                }
            }
            if let removePart { parts.removeAll { ($0["id"] as? String) == removePart } }
            list[i]["parts"] = parts
        } else if let part {
            list[i]["parts"] = [part]
        }
        messages[sid] = list
    }

    func deleteMessages(_ sid: String, from messageID: String) {
        lock.lock(); defer { lock.unlock() }
        var list = messages[sid] ?? []
        let idx = list.firstIndex { (($0["info"] as? [String: Any])?["id"] as? String) == messageID } ?? list.count
        reverted[sid] = Array(list[idx...])
        list.removeSubrange(idx...)
        messages[sid] = list
    }

    func restoreMessages(_ sid: String) {
        lock.lock(); defer { lock.unlock() }
        guard let back = reverted[sid] else { return }
        messages[sid] = (messages[sid] ?? []) + back
        reverted[sid] = nil
    }

    func truncateForFork(_ sid: String, before messageID: String?) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let list = messages[sid] ?? []
        guard let messageID else { return list }
        let idx = list.firstIndex { (($0["info"] as? [String: Any])?["id"] as? String) == messageID } ?? list.count
        return Array(list[..<idx])
    }

    func setMessages(_ sid: String, _ list: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        messages[sid] = list
    }

    func todos(_ sid: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return todos[sid] ?? []
    }

    func setTodos(_ sid: String, _ list: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        todos[sid] = list
    }

    func diffs(_ sid: String) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return diffs[sid] ?? []
    }

    func addDiff(_ sid: String, file: String, before: String, after: String) {
        lock.lock(); defer { lock.unlock() }
        let additions = after.split(separator: "\n", omittingEmptySubsequences: false).count
        let removals = before.split(separator: "\n", omittingEmptySubsequences: false).count
        var list = diffs[sid] ?? []
        list.removeAll { ($0["file"] as? String) == file }
        list.append([
            "file": file,
            "before": before,
            "after": after,
            "additions": max(0, additions - 1),
            "deletions": max(0, removals - 1)
        ])
        diffs[sid] = list
    }
}