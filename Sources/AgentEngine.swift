import Foundation
import UIKit
import Darwin

/// A tiny on-device implementation of the opencode v1 HTTP surface, backed by
/// OpenCode Zen and ios_system. The bundled web UI talks to it through WebBridge.
final class AgentEngine {
    static let shared = AgentEngine()

    weak var bridge: WebBridge?
    /// Native SwiftUI observers receive the same opencode events as the web bridge.
    var eventHandler: (([String: Any]) -> Void)?
    private let store = AgentStore.shared
    private let zen = ZenClient.shared
    private let shell = ShellRunner.shared
    private var running: [String: Task<Void, Never>] = [:]
    private let lock = NSRecursiveLock()
    private var initialized = false
    private var agentPrompts: [String: String] = [:]
    private var agentModels: [String: String] = [:]
    private var agentDescriptions: [String: String] = [:]
    private var agentModes: [String: String] = [:]
    private var instructionText = ""
    private var disabledTools: Set<String> = []
    private var defaultAgent = "build"

    private init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.store.statusesSnapshot().forEach { sid, _ in self.store.setStatus(sid, "idle") }
            Task { await self.zen.refreshCatalog() }
        }
    }

    func start() {
        guard !initialized else { return }
        initialized = true
        AgentPaths.prepare()
        reloadConfig()
        _ = zen.defaultModel()
    }

    func reloadConfig() {
        let cfg = loadConfig()
        var prompts: [String: String] = [:]
        var models: [String: String] = [:]
        var descriptions: [String: String] = [:]
        var modes: [String: String] = [:]

        func ingest(_ dict: [String: Any]) {
            for (name, value) in dict {
                guard let a = value as? [String: Any] else { continue }
                if let p = (a["prompt"] as? String) ?? (a["system"] as? String), !p.isEmpty { prompts[name] = p }
                if let m = modelID(a["model"]) { models[name] = m }
                if let d = a["description"] as? String { descriptions[name] = d }
                if let m = a["mode"] as? String { modes[name] = m }
            }
        }
        if let a = cfg["agents"] as? [String: Any] { ingest(a) }
        if let a = cfg["agent"] as? [String: Any] { ingest(a) }
        agentPrompts = prompts
        agentModels = models
        agentDescriptions = descriptions
        agentModes = modes
        if let d = cfg["default_agent"] as? String, !d.isEmpty { defaultAgent = d }

        if let m = modelID(cfg["model"]) {
            ServerConfig.shared.zenModel = m
        }
        if let providers = cfg["providers"] as? [String: Any],
           let open = providers["opencode"] as? [String: Any],
           let opts = open["options"] as? [String: Any],
           let key = opts["apiKey"] as? String, !key.isEmpty, !key.hasPrefix("{env:") {
            if ServerConfig.shared.zenKey != key { ServerConfig.shared.zenKey = key }
        } else if let providers = cfg["provider"] as? [String: Any],
                  let open = providers["opencode"] as? [String: Any],
                  let opts = open["options"] as? [String: Any],
                  let key = opts["apiKey"] as? String, !key.isEmpty, !key.hasPrefix("{env:") {
            if ServerConfig.shared.zenKey != key { ServerConfig.shared.zenKey = key }
        }

        var disabled: Set<String> = []
        if let rules = cfg["permissions"] as? [[String: Any]] {
            for r in rules {
                if (r["effect"] as? String) == "deny", let action = r["action"] as? String {
                    disabled.insert(normalizePermission(action))
                }
            }
        }
        if let old = cfg["permission"] as? [String: Any] {
            for (k, v) in old {
                if let s = v as? String, s == "deny" { disabled.insert(normalizePermission(k)) }
                if let d = v as? [String: Any], (d["*"] as? String) == "deny" { disabled.insert(normalizePermission(k)) }
            }
        }
        if let tools = cfg["tools"] as? [String: Any] {
            for (k, v) in tools where (v as? Bool) == false { disabled.insert(normalizePermission(k)) }
        }
        disabledTools = disabled

        var chunks: [String] = []
        if let list = cfg["instructions"] as? [String] {
            for item in list {
                chunks.append(contentsOf: readInstruction(item))
            }
        }
        let agentsFile = AgentPaths.workspace.appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agentsFile.path),
           let txt = try? String(contentsOf: agentsFile, encoding: .utf8) {
            chunks.append(txt)
        }
        var seen = Set<String>()
        instructionText = chunks.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
    }

    private func normalizePermission(_ key: String) -> String {
        switch key {
        case "write", "edit", "delete", "move", "mkdir": return "edit"
        case "read", "list", "grep", "glob": return "read"
        default: return key
        }
    }

    private func modelID(_ value: Any?) -> String? {
        if let s = value as? String, s.contains("/") { return String(s.split(separator: "/").last ?? "") }
        if let obj = value as? [String: Any] {
            if let m = obj["model"] as? String { return m }
            if let m = obj["modelID"] as? String { return m }
        }
        return nil
    }

    private func readInstruction(_ item: String) -> [String] {
        if item.hasPrefix("http://") || item.hasPrefix("https://") { return [] }
        var path = item
        if path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasSuffix("/**") { path.removeLast(3) }
        guard let url = AgentPaths.resolve(path) else { return [] }
        var urls: [URL] = []
        if path.contains("*") {
            let dir = url.deletingLastPathComponent()
            if let list = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                urls = list.filter { $0.pathExtension == "md" }
            }
        } else {
            urls = [url]
        }
        return urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.map { String($0.prefix(30_000)) }
    }

    // MARK: - SSE helpers

    func startEvents() {
        emit("server.connected", [:])
    }

    private func emit(_ type: String, _ properties: [String: Any]) {
        let payload: [String: Any] = ["type": type, "properties": properties]
        let event: [String: Any] = [
            "directory": AgentPaths.workspace.path,
            "payload": payload
        ]
        bridge?.emitSSE(jsonText(event))
        eventHandler?(payload)
    }

    private func emitMessage(_ sid: String, _ info: [String: Any]) {
        emit("message.updated", ["info": info])
        store.updateSession(sid)
    }

    private func emitPart(_ sid: String, _ mid: String, _ part: [String: Any]) {
        var p = part
        p["sessionID"] = sid
        p["messageID"] = mid
        emit("message.part.updated", ["part": p])
    }

    private func emitDelta(_ sid: String, _ mid: String, _ pid: String, _ field: String, _ delta: String) {
        emit("message.part.delta", [
            "sessionID": sid, "messageID": mid, "partID": pid,
            "field": field, "delta": delta
        ])
    }

    // MARK: - HTTP surface

    func handle(method: String, path: String, body: String) -> (Int, Any?) {
        start()
        let (route, query) = splitPath(path)
        let parts = route.split(separator: "/").map(String.init)
        let payload = parseJSON(body)

        if route == "/global/health" { return (200, ["healthy": true, "version": "1.0.0-ios"]) }
        if route == "/global/event" || route == "/event" { return (200, ["ok": true]) }
        if route == "/doc" || route == "/openapi.json" { return (404, ["error": "not found"]) }

        if route == "/config/providers" { return (200, providersPayload()) }
        if route == "/config" {
            if method == "GET" { return (200, loadConfig()) }
            if method == "PATCH" || method == "PUT" { return (200, saveConfig(payload)) }
        }
        if route == "/provider" {
            let models = zen.selectableModels
            return (200, [
                "all": [["id": "opencode", "name": "OpenCode Zen"]],
                "connected": zen.anonymous ? [] : ["opencode"],
                "default": ["opencode": zen.defaultModel()],
                "models": models.count
            ])
        }
        if route == "/provider/auth" {
            return (200, ["opencode": [["type": "api", "label": "API-ключ OpenCode Console"]]])
        }
        if route == "/experimental/console/orgs" {
            if let email = zen.accountEmail {
                return (200, ["orgs": [["accountEmail": email, "orgName": "OpenCode", "active": true]]])
            }
            return (200, ["orgs": []])
        }
        if route == "/agent" {
            return (200, agentsPayload())
        }
        if route == "/command" { return (200, []) }
        if route == "/project" || route == "/project/current" {
            let p: [String: Any] = ["id": "local", "worktree": AgentPaths.workspace.path, "name": "OpenCode"]
            return (200, route == "/project" ? [p] : p)
        }
        if route == "/vcs" { return (200, ["branch": ""]) }
        if route == "/path" { return (200, ["cwd": AgentPaths.workspace.path, "root": AgentPaths.workspace.path]) }
        if route == "/mcp" { return (200, [:]) }
        if route == "/lsp" { return (200, []) }
        if route == "/formatter" { return (200, []) }
        if route == "/permission" || route == "/question" { return (200, []) }
        if route == "/file" {
            return (200, listFiles(query["path"] ?? "."))
        }
        if route == "/file/content" {
            return (200, readFileContent(query["path"] ?? ""))
        }
        if route == "/file/status" {
            let all = store.allSessions().flatMap { store.diffs($0["id"] as? String ?? "") }
            return (200, all.map { ["path": $0["file"] as? String ?? "", "status": "modified",
                                   "added": $0["additions"] as? Int ?? 0, "removed": $0["deletions"] as? Int ?? 0] })
        }
        if route == "/find/file" {
            return (200, findFiles(query["query"] ?? "", limit: Int(query["limit"] ?? "") ?? 30))
        }
        if route == "/find" {
            return (200, grep(query["pattern"] ?? "", path: query["path"] ?? "."))
        }

        // sessions
        if route == "/session" {
            if method == "GET" { return (200, store.allSessions()) }
            if method == "POST" {
                let title = payload["title"] as? String
                let s = store.createSession(title: title ?? "Новая сессия", parentID: payload["parentID"] as? String)
                emit("session.created", ["info": s])
                return (200, s)
            }
        }
        if route == "/session/status" {
            var out: [String: Any] = [:]
            store.statusesSnapshot().forEach { out[$0.key] = ["type": $0.value] }
            return (200, out)
        }
        if parts.count >= 2 && parts[0] == "session" {
            let sid = parts[1]
            if parts.count == 2 {
                guard let s = store.session(sid) else { return (404, ["error": "session not found"]) }
                if method == "GET" { return (200, s) }
                if method == "PATCH" {
                    store.updateSession(sid, title: payload["title"] as? String)
                    if let updated = store.session(sid) {
                        emit("session.updated", ["info": updated])
                        return (200, updated)
                    }
                }
                if method == "DELETE" {
                    if let t = running[sid] { t.cancel() }
                    running[sid] = nil
                    store.deleteSession(sid)
                    emit("session.deleted", ["info": s])
                    return (200, true)
                }
            }
            guard let s = store.session(sid) else { return (404, ["error": "session not found"]) }
            if parts.count >= 3 {
                switch parts[2] {
                case "message":
                    if method == "GET" { return (200, store.allMessages(sid)) }
                    if method == "POST" { startPrompt(sessionID: sid, body: payload); return (204, nil) }
                case "prompt_async":
                    startPrompt(sessionID: sid, body: payload)
                    return (204, nil)
                case "abort":
                    running[sid]?.cancel()
                    running[sid] = nil
                    store.setStatus(sid, "idle")
                    emit("session.status", ["sessionID": sid, "status": ["type": "idle"]])
                    emit("session.idle", ["sessionID": sid])
                    return (200, true)
                case "todo":
                    return (200, store.todos(sid))
                case "diff":
                    return (200, store.diffs(sid))
                case "revert":
                    if let mid = payload["messageID"] as? String {
                        store.deleteMessages(sid, from: mid)
                        emit("session.updated", ["info": s])
                    }
                    return (200, true)
                case "unrevert":
                    store.restoreMessages(sid)
                    emit("session.updated", ["info": s])
                    return (200, true)
                case "fork":
                    let new = store.createSession(title: (s["title"] as? String ?? "Сессия") + " (fork)")
                    let copied = store.truncateForFork(sid, before: payload["messageID"] as? String)
                    store.setMessages(new["id"] as? String ?? "", copied)
                    emit("session.created", ["info": new])
                    return (200, new)
                case "share":
                    if method == "DELETE" { return (200, true) }
                    return (200, ["share": ["url": ""]])
                case "summarize", "init", "command", "shell":
                    return (200, false)
                case "children":
                    return (200, store.allSessions().filter { ($0["parentID"] as? String) == sid })
                default:
                    break
                }
            }
        }

        if parts.count >= 2 && parts[0] == "auth" && parts[1] == "opencode" {
            if method == "DELETE" {
                zen.logout()
                return (200, true)
            }
            if method == "PUT" {
                if let key = payload["key"] as? String, !key.isEmpty {
                    zen.cancelLogin()
                    ServerConfig.shared.zenAccess = ""
                    ServerConfig.shared.zenRefresh = ""
                    ServerConfig.shared.zenEmail = ""
                    ServerConfig.shared.zenKey = key
                    return (200, true)
                }
                return (400, ["error": "key required"])
            }
        }

        if parts.count >= 3 && parts[0] == "permission" && parts[2] == "reply" { return (200, true) }
        if parts.count >= 3 && parts[0] == "question" && parts[2] == "reply" { return (200, true) }
        if parts.count >= 3 && parts[0] == "question" && parts[2] == "reject" { return (200, true) }

        if parts.count >= 3 && parts[0] == "pty" {
            if parts[2] == "connect" { return (200, ["ok": true]) }
        }
        if route == "/pty" {
            if method == "GET" { return (200, [["id": "pty_local", "title": "shell", "cwd": AgentPaths.workspace.path, "status": "running"]]) }
            if method == "POST" { return (200, ["id": "pty_local", "title": "shell", "cwd": AgentPaths.workspace.path, "status": "running"]) }
        }
        if parts.count >= 2 && parts[0] == "pty" {
            return (200, true)
        }

        if route == "/instance/dispose" || route == "/log" || route.hasPrefix("/tui/") { return (200, true) }
        if route == "/model" || route == "/skill" || route == "/reference" { return (200, []) }

        return (404, ["error": "not found", "path": route])
    }

    private func splitPath(_ raw: String) -> (String, [String: String]) {
        guard let q = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let route = String(raw[..<q])
        let queryText = String(raw[raw.index(after: q)...])
        var query: [String: String] = [:]
        for pair in queryText.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                let k = kv[0].removingPercentEncoding ?? kv[0]
                let v = kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]
                query[k] = v
            }
        }
        return (route, query)
    }

    private func parseJSON(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - config

    private func loadConfig() -> [String: Any] {
        var cfg: [String: Any] = [:]
        let user = AgentPaths.userConfigFile
        let internalCfg = AgentPaths.configFile
        if let text = try? String(contentsOf: user, encoding: .utf8),
           let data = stripJSONC(text).data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cfg = obj
        } else if let text = try? String(contentsOf: internalCfg, encoding: .utf8),
                  let data = stripJSONC(text).data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            cfg = obj
        }
        let hasModel = (cfg["model"] as? String)?.isEmpty == false || cfg["model"] is [String: Any]
        if !hasModel {
            cfg["model"] = "opencode/\(zen.defaultModel())"
        }
        if cfg["plugins"] == nil { cfg["plugins"] = [] }
        if cfg["plugin"] == nil { cfg["plugin"] = [] }
        if cfg["mcp"] == nil { cfg["mcp"] = [:] }
        return cfg
    }

    private func saveConfig(_ patch: [String: Any]) -> [String: Any] {
        var cfg = loadConfig()
        patch.forEach { cfg[$0.key] = $0.value }
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: AgentPaths.userConfigFile, options: .atomic)
        }
        reloadConfig()
        return cfg
    }

    private func agentsPayload() -> [[String: Any]] {
        var list: [[String: Any]] = [
            ["name": "build", "mode": "primary", "description": agentDescriptions["build"] ?? "Пишет код и меняет файлы"],
            ["name": "plan", "mode": "primary", "description": agentDescriptions["plan"] ?? "Только читает и планирует"],
            ["name": "general", "mode": "subagent", "description": "Исследует проект"]
        ]
        for (name, mode) in agentModes where !["build", "plan", "general"].contains(name) {
            list.append(["name": name, "mode": mode, "description": agentDescriptions[name] ?? ""])
        }
        for name in agentPrompts.keys where !["build", "plan", "general"].contains(name) && agentModes[name] == nil {
            list.append(["name": name, "mode": "primary", "description": agentDescriptions[name] ?? ""])
        }
        list.sort { a, b in
            let an = a["name"] as? String ?? ""
            let bn = b["name"] as? String ?? ""
            if an == defaultAgent { return true }
            if bn == defaultAgent { return false }
            let am = a["mode"] as? String == "subagent" ? 1 : 0
            let bm = b["mode"] as? String == "subagent" ? 1 : 0
            return am < bm
        }
        return list
    }

    private func providersPayload() -> [String: Any] {
        reloadConfig()
        var map: [String: Any] = [:]
        for m in zen.selectableModels { map[m.id] = m.ui }
        return [
            "providers": [[
                "id": "opencode",
                "name": "OpenCode Zen",
                "models": map
            ]],
            "default": ["opencode": zen.defaultModel()]
        ]
    }

    // MARK: - files

    private func listFiles(_ raw: String) -> [[String: Any]] {
        guard let dir = AgentPaths.resolve(raw) else { return [] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url in
            let rel = AgentPaths.relative(url)
            if rel.hasPrefix(".opencode") || rel.hasPrefix(".git") { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            return [
                "name": url.lastPathComponent,
                "path": rel,
                "absolute": url.path,
                "type": isDirectory ? "directory" : "file",
                "ignored": false,
                "size": values?.fileSize ?? 0
            ]
        }.sorted {
            let a = ($0["type"] as? String) == "directory" ? 0 : 1
            let b = ($1["type"] as? String) == "directory" ? 0 : 1
            if a != b { return a < b }
            return ($0["name"] as? String ?? "").localizedCaseInsensitiveCompare($1["name"] as? String ?? "") == .orderedAscending
        }
    }

    private func readFileContent(_ raw: String) -> [String: Any] {
        guard let url = AgentPaths.resolve(raw), FileManager.default.fileExists(atPath: url.path) else {
            return ["type": "text", "content": "", "error": "not found"]
        }
        let ext = url.pathExtension.lowercased()
        let image = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"].contains(ext)
        if image, let data = try? Data(contentsOf: url) {
            return ["type": "file", "encoding": "base64", "mimeType": "image/\(ext == "jpg" ? "jpeg" : ext)",
                    "content": data.base64EncodedString()]
        }
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000,
              let text = String(data: data, encoding: .utf8) else {
            return ["type": "text", "content": "Бинарный файл — не отображается"]
        }
        return ["type": "text", "content": text]
    }

    private func findFiles(_ query: String, limit: Int) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        var out: [String] = []
        let root = AgentPaths.workspace
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            if out.count >= max(1, min(limit, 200)) { break }
            let name = url.lastPathComponent.lowercased()
            if name.contains(q) {
                var rel = AgentPaths.relative(url)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { rel += "/" }
                out.append(rel)
            }
        }
        return out
    }

    private func grep(_ pattern: String, path: String) -> [[String: Any]] {
        guard !pattern.isEmpty, let base = AgentPaths.resolve(path) else { return [] }
        var hits: [[String: Any]] = []
        let files = walkFiles(base)
        for file in files {
            if hits.count >= 100 { break }
            guard let data = try? Data(contentsOf: file), data.count < 1_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    hits.append(["path": AgentPaths.relative(file), "line_number": i + 1, "lines": String(line)])
                    if hits.count >= 100 { break }
                }
            }
        }
        return hits
    }

    private func walkFiles(_ root: URL) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e {
            let rel = AgentPaths.relative(url)
            if rel.hasPrefix(".opencode") || rel.hasPrefix(".git") || rel.contains("node_modules/") || rel.contains(".git/") { continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            out.append(url)
            if out.count > 3000 { break }
        }
        return out
    }

    // MARK: - prompt / agent loop

    private func startPrompt(sessionID: String, body: [String: Any]) {
        reloadConfig()
        guard let session = store.session(sessionID) else { return }
        let mid = body["messageID"] as? String ?? newID("msg_")
        let agent = body["agent"] as? String ?? defaultAgent
        let modelObj = body["model"] as? [String: Any] ?? [:]
        let modelID = modelObj["modelID"] as? String ?? agentModels[agent] ?? modelFromConfig()
        let providerID = modelObj["providerID"] as? String ?? "opencode"
        var parts = body["parts"] as? [[String: Any]] ?? []
        if parts.isEmpty, let text = body["text"] as? String {
            parts = [["type": "text", "text": text]]
        }

        let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if (session["title"] as? String ?? "Новая сессия") == "Новая сессия" && !text.isEmpty {
            store.updateSession(sessionID, title: String(text.prefix(70)).replacingOccurrences(of: "\n", with: " "))
        }
        if let updated = store.session(sessionID) { emit("session.updated", ["info": updated]) }

        var normalizedParts: [[String: Any]] = []
        for (i, var p) in parts.enumerated() {
            p["id"] = p["id"] as? String ?? newID("prt_")
            p["sessionID"] = sessionID
            p["messageID"] = mid
            p["_order"] = i
            normalizedParts.append(p)
        }
        let info: [String: Any] = [
            "id": mid, "sessionID": sessionID, "role": "user",
            "time": ["created": nowMs()],
            "agent": agent,
            "model": ["providerID": providerID, "modelID": modelID]
        ]
        store.appendMessage(sessionID, ["info": info, "parts": normalizedParts])
        emitMessage(sessionID, info)
        for p in normalizedParts { emitPart(sessionID, mid, p) }

        store.setStatus(sessionID, "busy")
        emit("session.status", ["sessionID": sessionID, "status": ["type": "busy"]])
        store.updateSession(sessionID)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(sessionID: sessionID, modelID: modelID, agent: agent)
        }
        lock.lock()
        running[sessionID]?.cancel()
        running[sessionID] = task
        lock.unlock()
    }

    private func modelFromConfig() -> String {
        let cfg = loadConfig()
        if let m = cfg["model"] as? String, m.contains("/") {
            return String(m.split(separator: "/").last ?? "")
        }
        return zen.defaultModel()
    }

    private func finish(sessionID: String) {
        store.setStatus(sessionID, "idle")
        store.updateSession(sessionID)
        store.save()
        emit("session.status", ["sessionID": sessionID, "status": ["type": "idle"]])
        emit("session.idle", ["sessionID": sessionID])
        lock.lock(); running[sessionID] = nil; lock.unlock()
    }

    private func runAgent(sessionID: String, modelID: String, agent: String) async {
        var iterations = 0
        var totalInput = 0
        var totalOutput = 0
        var totalReasoning = 0
        var totalCost = 0.0

        while iterations < 12 {
            if Task.isCancelled { finish(sessionID: sessionID); return }
            iterations += 1
            let assistantID = newID("msg_")
            var info: [String: Any] = [
                "id": assistantID, "sessionID": sessionID, "role": "assistant",
                "providerID": "opencode", "modelID": modelID,
                "time": ["created": nowMs()]
            ]
            store.appendMessage(sessionID, ["info": info, "parts": []])
            emitMessage(sessionID, info)

            var text = ""
            var reasoning = ""
            var textPart: [String: Any]? = nil
            var reasoningPart: [String: Any]? = nil
            var toolParts: [[String: Any]] = []

            do {
                let free = (zen.model(modelID)?.free ?? false) && FreeAgentProfile.shared.available
                let system = free ? FreeAgentProfile.shared.system(model: modelID) : systemPrompt(agent: agent)
                let messages = buildProviderMessages(sessionID: sessionID, system: system)
                let tools = free ? FreeAgentProfile.shared.tools(readOnly: agent == "plan") : toolSchemas(readOnly: agent == "plan")
                let result = try await zen.stream(model: modelID, sessionID: sessionID, messages: messages, tools: tools) { field, delta in
                    if field == "text" {
                        text += delta
                        if textPart == nil {
                            textPart = ["id": newID("prt_"), "type": "text", "text": ""]
                            if var p = textPart {
                                p["sessionID"] = sessionID; p["messageID"] = assistantID
                                textPart = p
                                self.store.updateMessage(sessionID, assistantID, part: p)
                                self.emitPart(sessionID, assistantID, p)
                            }
                        }
                        if let p = textPart, let pid = p["id"] as? String {
                            self.emitDelta(sessionID, assistantID, pid, "text", delta)
                        }
                    } else {
                        reasoning += delta
                        if reasoningPart == nil {
                            reasoningPart = ["id": newID("prt_"), "type": "reasoning", "text": "", "time": ["start": nowMs()]]
                            if var p = reasoningPart {
                                p["sessionID"] = sessionID; p["messageID"] = assistantID
                                reasoningPart = p
                                self.store.updateMessage(sessionID, assistantID, part: p)
                                self.emitPart(sessionID, assistantID, p)
                            }
                        }
                        if let p = reasoningPart, let pid = p["id"] as? String {
                            self.emitDelta(sessionID, assistantID, pid, "text", delta)
                        }
                    }
                }

                if Task.isCancelled { finish(sessionID: sessionID); return }

                let usage = result.usage
                totalInput += usage["input"] as? Int ?? 0
                totalOutput += usage["output"] as? Int ?? 0
                totalReasoning += usage["reasoning"] as? Int ?? 0
                totalCost += result.cost

                if var p = textPart {
                    p["text"] = text
                    p["sessionID"] = sessionID; p["messageID"] = assistantID
                    store.updateMessage(sessionID, assistantID, part: p)
                    emitPart(sessionID, assistantID, p)
                }
                if var p = reasoningPart {
                    p["text"] = reasoning
                    let started = ((p["time"] as? [String: Any])?["start"] as? NSNumber)?.int64Value ?? nowMs()
                    p["time"] = ["start": started, "end": nowMs()]
                    p["sessionID"] = sessionID; p["messageID"] = assistantID
                    store.updateMessage(sessionID, assistantID, part: p)
                    emitPart(sessionID, assistantID, p)
                }

                for call in result.toolCalls {
                    if Task.isCancelled { break }
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                    var part: [String: Any] = [
                        "id": newID("prt_"), "sessionID": sessionID, "messageID": assistantID,
                        "type": "tool", "callID": call.id, "tool": call.name,
                        "state": ["status": "running", "input": input, "title": call.name, "time": ["start": nowMs()]]
                    ]
                    store.updateMessage(sessionID, assistantID, part: part)
                    emitPart(sessionID, assistantID, part)

                    let outcome = await executeTool(name: call.name, input: input, sessionID: sessionID)
                    var state: [String: Any] = [
                        "status": outcome.error == nil ? "completed" : "error",
                        "input": input,
                        "title": call.name,
                        "time": ["start": ((part["state"] as? [String: Any])?["time"] as? [String: Any])?["start"] as? Int64 ?? nowMs(), "end": nowMs()],
                        "output": outcome.output
                    ]
                    if let err = outcome.error { state["error"] = err }
                    if let meta = outcome.metadata { state["metadata"] = meta }
                    part["state"] = state
                    store.updateMessage(sessionID, assistantID, part: part)
                    emitPart(sessionID, assistantID, part)
                    toolParts.append(part)
                }

                var completed = info
                completed["time"] = ["created": ((info["time"] as? [String: Any])?["created"] as? NSNumber)?.int64Value ?? nowMs(), "completed": nowMs()]
                completed["tokens"] = [
                    "input": totalInput, "output": totalOutput,
                    "reasoning": totalReasoning,
                    "cache": ["read": 0, "write": 0]
                ]
                completed["cost"] = totalCost
                store.updateMessage(sessionID, assistantID, info: completed)
                emitMessage(sessionID, completed)
                info = completed

                if result.toolCalls.isEmpty {
                    finish(sessionID: sessionID)
                    return
                }
                if agent == "plan" {
                    finish(sessionID: sessionID)
                    return
                }
                // Continue the loop so the model can see tool results and answer.
            } catch {
                let message: String
                if let ze = error as? ZenError {
                    if ze.status == 401 {
                        message = "Нужен вход в аккаунт OpenCode или API-ключ. Откройте Настройки → Аккаунт opencode."
                    } else if ze.status == 403 && ze.message.lowercased().contains("free") {
                        message = "Это бесплатная модель. Console разрешает их только официальному OpenCode. Выберите платную модель или ключ Go."
                    } else if ze.isQuota {
                        message = "Лимит этой модели/аккаунта. С API-ключом выбирайте платную модель: бесплатные работают только в официальном OpenCode. Для ключа Go приложение само пробует /inference/go; при нулевом балансе пополните Console."
                    } else {
                        message = ze.message
                    }
                } else {
                    message = shortError(error)
                }
                var failed = info
                failed["time"] = ["created": ((info["time"] as? [String: Any])?["created"] as? NSNumber)?.int64Value ?? nowMs(), "completed": nowMs()]
                failed["error"] = ["name": "ProviderError", "data": ["message": message]]
                store.updateMessage(sessionID, assistantID, info: failed)
                emitMessage(sessionID, failed)
                emit("session.error", ["sessionID": sessionID, "error": ["name": "ProviderError", "data": ["message": message]]])
                finish(sessionID: sessionID)
                return
            }
        }
        finish(sessionID: sessionID)
    }

    // MARK: - provider history

    private func systemPrompt(agent: String) -> String {
        let mode = agent == "plan"
            ? "Режим plan: только анализируй, ищи и планируй. Не меняй файлы и не выполняй изменяющие команды."
            : "Режим build: можешь читать и менять файлы, выполнять команды."
        let base = agentPrompts[agent] ?? "Ты OpenCode — AI-агент для программирования."
        let rules = """
        Ты работаешь полностью на iPhone, в песочнице приложения.
        Рабочая папка: \(AgentPaths.workspace.path)
        \(mode)

        У тебя есть настоящий Unix-shell (ios_system) и файловые инструменты.
        Доступны команды: ls, cat, head, tail, grep, egrep, sed, awk, sort, uniq, wc, cut, tr, diff, find, xargs, cp, mv, rm, mkdir, rmdir, touch, chmod, stat, du, df, tar, gzip, gunzip, date, echo, env, pwd, tee, uname, whoami, bc.
        Git работает через встроенный libgit2: git init, status, add, reset, commit -m, log, diff, branch, checkout, rev-parse, remote, config, clone. Для pull/push используй веб-поиск/ручное управление, они не поддерживаются.
        Python 3.13 доступен как beta: python3 script.py и python3 -c "код". Нет pip и компиляторов; ssl/sqlite3 включены.
        Недоступны: node, npm, компиляторы, установка пакетов. Не пытайся их запускать.
        Для правок используй инструменты edit/write; для осмотра — read/list/grep/bash.
        Все пути — внутри рабочей папки. Не выходи за её пределы.
        Сначала изучи файлы, потом меняй. Делай минимальные аккуратные изменения.
        Для многошаговых задач используй todowrite.
        Отвечай на языке пользователя, кратко и по делу. Код — в блоках ```.
        """
        if instructionText.isEmpty { return base + "\n\n" + rules }
        return base + "\n\n" + rules + "\n\nПравила проекта:\n" + String(instructionText.prefix(60_000))
    }

    private func buildProviderMessages(sessionID: String, system: String) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        var budget = 120_000
        let all = store.allMessages(sessionID)
        for message in all.suffix(40) {
            guard let info = message["info"] as? [String: Any],
                  let parts = message["parts"] as? [[String: Any]] else { continue }
            let role = info["role"] as? String ?? ""
            if role == "user" {
                let content = userContent(parts)
                if content.isEmpty { continue }
                out.append(["role": "user", "content": String(content.prefix(max(0, budget)))])
                budget -= min(content.count, budget)
            } else if role == "assistant" {
                let text = parts.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                let calls = parts.filter { ($0["type"] as? String) == "tool" }
                if text.isEmpty && calls.isEmpty { continue }
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = text.isEmpty ? NSNull() : String(text.prefix(30_000))
                if !calls.isEmpty {
                    var toolCalls: [[String: Any]] = []
                    for p in calls {
                        guard let cid = p["callID"] as? String, let name = p["tool"] as? String else { continue }
                        let input = (p["state"] as? [String: Any])?["input"] as? [String: Any] ?? [:]
                        let args = jsonText(input)
                        toolCalls.append(["id": cid, "type": "function", "function": ["name": name, "arguments": args]])
                    }
                    if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
                }
                out.append(msg)
                for p in calls {
                    guard let cid = p["callID"] as? String else { continue }
                    let state = p["state"] as? [String: Any] ?? [:]
                    let output = state["output"] as? String ?? state["error"] as? String ?? ""
                    out.append(["role": "tool", "tool_call_id": cid, "content": String(output.prefix(20_000))])
                }
                budget -= min(text.count, max(0, budget))
            }
            if budget <= 0 { break }
        }
        return out
    }

    private func userContent(_ parts: [[String: Any]]) -> String {
        var chunks: [String] = []
        for p in parts {
            let type = p["type"] as? String ?? ""
            if type == "text", let t = p["text"] as? String, !t.isEmpty { chunks.append(t) }
            if type == "file" {
                let name = p["filename"] as? String ?? "файл"
                let mime = p["mime"] as? String ?? ""
                if mime.hasPrefix("text/"), let url = p["url"] as? String, let data = decodeDataURL(url),
                   let text = String(data: data, encoding: .utf8) {
                    chunks.append("\n\n--- \(name) ---\n\(String(text.prefix(20_000)))")
                } else if let source = p["source"] as? [String: Any],
                          let path = (source["path"] as? String) ?? ((source["text"] as? [String: Any])?["value"] as? String),
                          let file = AgentPaths.resolve(path), let text = try? String(contentsOf: file, encoding: .utf8) {
                    chunks.append("\n\n--- \(AgentPaths.relative(file)) ---\n\(String(text.prefix(20_000)))")
                } else {
                    chunks.append("[прикреплён файл: \(name)]")
                }
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeDataURL(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let meta = String(url[..<comma])
        guard meta.contains(";base64") else { return String(url[url.index(after: comma)...]).data(using: .utf8) }
        let b64 = String(url[url.index(after: comma)...])
        return Data(base64Encoded: b64)
    }

    // MARK: - tools

    private struct ToolOutcome {
        var output: String
        var metadata: [String: Any]?
        var error: String?
    }

    private func toolSchemas(readOnly: Bool = false) -> [[String: Any]] {
        func fn(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": [
                "name": name, "description": desc,
                "parameters": ["type": "object", "properties": props, "required": required]
            ]]
        }
        let str: [String: Any] = ["type": "string"]
        let int: [String: Any] = ["type": "integer"]
        let bool: [String: Any] = ["type": "boolean"]
        var tools: [[String: Any]] = [
            fn("read", "Прочитать текстовый файл. offset/limit — номера строк.", ["filePath": str, "offset": int, "limit": int], ["filePath"]),
            fn("list", "Показать содержимое папки.", ["path": str], []),
            fn("grep", "Найти regex в текстовых файлах.", ["pattern": str, "path": str], ["pattern"]),
            fn("glob", "Найти файлы по glob-шаблону (например **/*.swift).", ["pattern": str], ["pattern"]),
            fn("webfetch", "Загрузить текст по URL.", ["url": str], ["url"]),
            fn("todowrite", "Обновить список задач сессии.", ["todos": ["type": "array", "items": ["type": "object"]]], ["todos"])
        ]
        if !readOnly {
            tools.insert(fn("bash", "Выполнить Unix-команду в рабочей папке. Доступны ls, cat, grep, sed, awk, find, sort, uniq, wc, diff, cp, mv, rm, mkdir, tar и другие. Нет node/python/git.", ["command": str, "workdir": str], ["command"]), at: 0)
            tools.append(fn("write", "Создать или полностью перезаписать файл.", ["filePath": str, "content": str], ["filePath", "content"]))
            tools.append(fn("edit", "Заменить точную строку oldString на newString в файле.", ["filePath": str, "oldString": str, "newString": str, "replaceAll": bool], ["filePath", "oldString", "newString"]))
            tools.append(fn("delete", "Удалить файл или папку внутри workspace.", ["filePath": str], ["filePath"]))
            tools.append(fn("move", "Переместить/переименовать файл.", ["from": str, "to": str], ["from", "to"]))
            tools.append(fn("mkdir", "Создать папку.", ["path": str], ["path"]))
        }
        return tools.filter { item in
            guard let fn = item["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return true }
            return !disabledTools.contains(normalizePermission(name))
        }
    }

    private func executeTool(name: String, input: [String: Any], sessionID: String) async -> ToolOutcome {
        if disabledTools.contains(normalizePermission(name)) {
            return ToolOutcome(output: "", metadata: nil, error: "Инструмент \(name) запрещён в config.json")
        }
        switch name {
        case "bash":
            let cmd = input["command"] as? String ?? ""
            let workdir = (input["workdir"] as? String).flatMap { AgentPaths.resolve($0)?.path } ?? AgentPaths.workspace.path
            let (code, output) = shell.run(cmd, cwd: workdir, timeout: 90)
            return ToolOutcome(output: output.isEmpty ? "(команда завершилась с кодом \(code), без вывода)" : output,
                               metadata: ["exit": Int(code)], error: nil)
        case "read":
            return readTool(input)
        case "write":
            return writeTool(input, sessionID: sessionID)
        case "edit":
            return editTool(input, sessionID: sessionID)
        case "list":
            let path = input["path"] as? String ?? "."
            let items = listFiles(path)
            let text = items.map { item -> String in
                let dir = (item["type"] as? String) == "directory"
                let name = item["name"] as? String ?? ""
                return dir ? "\(name)/" : "\(name)  \(item["size"] as? Int ?? 0) B"
            }.joined(separator: "\n")
            return ToolOutcome(output: text.isEmpty ? "(пусто)" : text, metadata: ["count": items.count], error: nil)
        case "grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String ?? "."
            let hits = grep(pattern, path: path)
            let text = hits.prefix(100).map { "\($0["path"] as? String ?? ""):\($0["line_number"] as? Int ?? 0): \($0["lines"] as? String ?? "")" }.joined(separator: "\n")
            return ToolOutcome(output: text.isEmpty ? "Совпадений нет" : text, metadata: ["count": hits.count], error: nil)
        case "glob":
            return globTool(input)
        case "webfetch":
            return await webFetchTool(input)
        case "todowrite":
            let list = input["todos"] as? [[String: Any]] ?? []
            store.setTodos(sessionID, list)
            emit("todo.updated", ["sessionID": sessionID, "todos": list])
            return ToolOutcome(output: "Задачи обновлены (\(list.count))", metadata: nil, error: nil)
        case "delete":
            guard let raw = input["filePath"] as? String, let url = AgentPaths.resolve(raw) else {
                return ToolOutcome(output: "", metadata: nil, error: "Путь вне workspace")
            }
            guard url.path != AgentPaths.workspace.path else {
                return ToolOutcome(output: "", metadata: nil, error: "Нельзя удалить корень workspace")
            }
            let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            do {
                try FileManager.default.removeItem(at: url)
                store.addDiff(sessionID, file: AgentPaths.relative(url), before: before, after: "")
                emit("session.diff", ["sessionID": sessionID, "diff": store.diffs(sessionID)])
                return ToolOutcome(output: "Удалено: \(AgentPaths.relative(url))", metadata: nil, error: nil)
            } catch { return ToolOutcome(output: "", metadata: nil, error: shortError(error)) }
        case "move":
            guard let from = input["from"] as? String, let to = input["to"] as? String,
                  let src = AgentPaths.resolve(from), let dst = AgentPaths.resolve(to) else {
                return ToolOutcome(output: "", metadata: nil, error: "Некорректные пути")
            }
            do {
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: src, to: dst)
                return ToolOutcome(output: "Перемещено: \(AgentPaths.relative(src)) → \(AgentPaths.relative(dst))", metadata: nil, error: nil)
            } catch { return ToolOutcome(output: "", metadata: nil, error: shortError(error)) }
        case "mkdir":
            guard let raw = input["path"] as? String, let url = AgentPaths.resolve(raw) else {
                return ToolOutcome(output: "", metadata: nil, error: "Некорректный путь")
            }
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return ToolOutcome(output: "Создана папка \(AgentPaths.relative(url))", metadata: nil, error: nil)
            } catch { return ToolOutcome(output: "", metadata: nil, error: shortError(error)) }
        default:
            return ToolOutcome(output: "", metadata: nil, error: "Неизвестный инструмент: \(name)")
        }
    }

    private func readTool(_ input: [String: Any]) -> ToolOutcome {
        guard let raw = input["filePath"] as? String, let url = AgentPaths.resolve(raw) else {
            return ToolOutcome(output: "", metadata: nil, error: "Некорректный путь")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ToolOutcome(output: "", metadata: nil, error: "Не удалось прочитать файл")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let offset = max(1, input["offset"] as? Int ?? 1)
        let limit = max(1, min(input["limit"] as? Int ?? 2000, 5000))
        let slice = lines.dropFirst(offset - 1).prefix(limit)
        let out = slice.enumerated().map { "\(offset + $0.offset)|\($0.element)" }.joined(separator: "\n")
        return ToolOutcome(output: out, metadata: ["lines": slice.count, "total": lines.count], error: nil)
    }

    private func writeTool(_ input: [String: Any], sessionID: String) -> ToolOutcome {
        guard let raw = input["filePath"] as? String, let content = input["content"] as? String,
              let url = AgentPaths.resolve(raw) else {
            return ToolOutcome(output: "", metadata: nil, error: "Некорректный путь или содержимое")
        }
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            store.addDiff(sessionID, file: AgentPaths.relative(url), before: before, after: content)
            emit("session.diff", ["sessionID": sessionID, "diff": store.diffs(sessionID)])
            return ToolOutcome(output: "Записано \(content.utf8.count) байт в \(AgentPaths.relative(url))",
                               metadata: ["diff": unifiedDiff(before, content, path: AgentPaths.relative(url))], error: nil)
        } catch { return ToolOutcome(output: "", metadata: nil, error: shortError(error)) }
    }

    private func editTool(_ input: [String: Any], sessionID: String) -> ToolOutcome {
        guard let raw = input["filePath"] as? String, let old = input["oldString"] as? String,
              let new = input["newString"] as? String, let url = AgentPaths.resolve(raw) else {
            return ToolOutcome(output: "", metadata: nil, error: "Некорректные параметры")
        }
        guard var text = try? String(contentsOf: url, encoding: .utf8) else {
            return ToolOutcome(output: "", metadata: nil, error: "Файл не найден")
        }
        let before = text
        if old.isEmpty {
            text = new
        } else if input["replaceAll"] as? Bool == true {
            text = text.replacingOccurrences(of: old, with: new)
        } else if let range = text.range(of: old) {
            text.replaceSubrange(range, with: new)
        } else {
            return ToolOutcome(output: "", metadata: nil, error: "oldString не найден в файле")
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.addDiff(sessionID, file: AgentPaths.relative(url), before: before, after: text)
            emit("session.diff", ["sessionID": sessionID, "diff": store.diffs(sessionID)])
            return ToolOutcome(output: "Изменено: \(AgentPaths.relative(url))",
                               metadata: ["diff": unifiedDiff(before, text, path: AgentPaths.relative(url))], error: nil)
        } catch { return ToolOutcome(output: "", metadata: nil, error: shortError(error)) }
    }

    private func globTool(_ input: [String: Any]) -> ToolOutcome {
        let pattern = input["pattern"] as? String ?? "*"
        let root = AgentPaths.workspace
        var results: [String] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles]) else {
            return ToolOutcome(output: "", metadata: nil, error: "Не удалось прочитать workspace")
        }
        for case let url as URL in e {
            if results.count >= 500 { break }
            let rel = AgentPaths.relative(url)
            if rel.hasPrefix(".opencode") { continue }
            let matches = pattern.withCString { p in
                rel.withCString { s in fnmatch(p, s, 0) == 0 }
                    || url.lastPathComponent.withCString { s in fnmatch(p, s, 0) == 0 }
            }
            if matches { results.append(rel) }
        }
        return ToolOutcome(output: results.isEmpty ? "Файлы не найдены" : results.joined(separator: "\n"),
                           metadata: ["count": results.count], error: nil)
    }

    private func webFetchTool(_ input: [String: Any]) async -> ToolOutcome {
        guard let raw = input["url"] as? String, let url = URL(string: raw),
              url.scheme == "http" || url.scheme == "https" else {
            return ToolOutcome(output: "", metadata: nil, error: "Некорректный URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 45
        req.setValue("OpenCode-Mobile-iOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return ToolOutcome(output: "", metadata: nil, error: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            var text = String(decoding: data, as: UTF8.self)
            if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") {
                text = text.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
                text = text.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
                text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                text = text.replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            }
            return ToolOutcome(output: String(text.prefix(60_000)), metadata: ["bytes": data.count], error: nil)
        } catch {
            return ToolOutcome(output: "", metadata: nil, error: shortError(error))
        }
    }

    private func unifiedDiff(_ before: String, _ after: String, path: String) -> String {
        if before == after { return "" }
        let a = before.split(separator: "\n", omittingEmptySubsequences: false)
        let b = after.split(separator: "\n", omittingEmptySubsequences: false)
        var out = "--- a/\(path)\n+++ b/\(path)\n@@ -1,\(a.count) +1,\(b.count) @@\n"
        out += a.map { "-\($0)" }.joined(separator: "\n")
        if !a.isEmpty { out += "\n" }
        out += b.map { "+\($0)" }.joined(separator: "\n")
        return String(out.prefix(120_000))
    }
}