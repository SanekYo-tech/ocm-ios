import Foundation
import SwiftUI

struct NativeSession: Identifiable, Hashable {
    let id: String
    var title: String
    var updated: Int64
}

struct NativePart: Identifiable {
    enum Kind: String { case text, reasoning, tool, other }

    let id: String
    var kind: Kind
    var text: String = ""
    var toolName: String = ""
    var inputSummary: String = ""
    var output: String = ""
    var status: String = ""
    var diff: String = ""
    var error: String = ""
}

struct NativeMessage: Identifiable {
    let id: String
    var role: String
    var parts: [NativePart] = []
    var error: String = ""
    var model: String = ""
    var tokens: Int = 0
    var duration: Double = 0
}

@MainActor
final class NativeChatStore: ObservableObject {
    @Published var sessions: [NativeSession] = []
    @Published var messages: [NativeMessage] = []
    @Published var currentSessionID: String?
    @Published var busy = false
    @Published var errorMessage: String?
    @Published var scrollTick = 0
    @Published var todos: [[String: Any]] = []
    @Published var selectedModel: String
    @Published var selectedAgent: String = "build"
    @Published var models: [ZenModel] = []
    @Published var loaded = false
    @Published var showingSessions = false
    @Published var showingModels = false

    private let engine = AgentEngine.shared
    private let zen = ZenClient.shared
    private var refreshing = false

    init() {
        let saved = UserDefaults.standard.string(forKey: "ocm.native.model") ?? ""
        let initial = ZenClient.shared.selectableModels
        selectedModel = (!saved.isEmpty && initial.contains(where: { $0.id == saved })) ? saved : ZenClient.shared.defaultModel()
        selectedAgent = UserDefaults.standard.string(forKey: "ocm.native.agent") ?? "build"
        engine.eventHandler = { [weak self] payload in
            Task { [weak self] in await MainActor.run { self?.handle(payload) } }
        }
    }

    func bootstrap() {
        guard !loaded else { return }
        loaded = true
        engine.start()
        models = zen.selectableModels
        loadSessions()
        // Always start with a fresh composer. Old sessions remain in the drawer;
        // this avoids showing a saved quota error from a previous attempt as if
        // it were a new model request.
        currentSessionID = nil
        messages = []
        todos = []
        Task {
            await ZenClient.shared.refreshCatalog()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.models = ZenClient.shared.selectableModels
                let available = self.models.map(\.id)
                if !available.contains(self.selectedModel) {
                    self.selectedModel = ZenClient.shared.defaultModel()
                    UserDefaults.standard.set(self.selectedModel, forKey: "ocm.native.model")
                }
            }
        }
    }

    // MARK: - sessions

    func loadSessions() {
        let (status, obj) = engine.handle(method: "GET", path: "/session", body: "")
        guard status == 200, let list = obj as? [[String: Any]] else { return }
        let mapped = list.compactMap { info -> NativeSession? in
            guard let id = info["id"] as? String else { return nil }
            let title = info["title"] as? String ?? "Новая сессия"
            let time = info["time"] as? [String: Any] ?? [:]
            let updated = (time["updated"] as? NSNumber)?.int64Value ?? 0
            return NativeSession(id: id, title: title, updated: updated)
        }
        sessions = mapped.sorted { $0.updated > $1.updated }
    }

    func openSession(_ id: String?) {
        currentSessionID = id
        messages = []
        todos = []
        errorMessage = nil
        guard let id else { return }
        UserDefaults.standard.set(id, forKey: "ocm.native.session")
        let (status, obj) = engine.handle(method: "GET", path: "/session/\(id)/message", body: "")
        guard status == 200, let list = obj as? [[String: Any]] else { return }
        messages = list.compactMap { item in
            guard let info = item["info"] as? [String: Any],
                  let parts = item["parts"] as? [[String: Any]] else { return nil }
            return message(from: info, parts: parts)
        }
        let statusObj = engine.handle(method: "GET", path: "/session/status", body: "").1 as? [String: Any]
        if let s = statusObj?[id] as? [String: Any], let type = s["type"] as? String {
            busy = type != "idle"
        } else {
            busy = false
        }
        bumpScroll()
    }

    func newSession() {
        let (status, obj) = engine.handle(method: "POST", path: "/session", body: "{}")
        if status >= 400 {
            errorMessage = "Не удалось создать сессию"
            return
        }
        if let info = obj as? [String: Any], let id = info["id"] as? String {
            upsertSession(info)
            openSession(id)
        }
    }

    func deleteSession(_ id: String) {
        _ = engine.handle(method: "DELETE", path: "/session/\(id)", body: "")
        var copy = sessions
        copy.removeAll { $0.id == id }
        sessions = copy
        if currentSessionID == id {
            openSession(sessions.first?.id)
        }
    }

    func renameSession(_ id: String, title: String) {
        let body = jsonText(["title": title])
        _ = engine.handle(method: "PATCH", path: "/session/\(id)", body: body)
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            var copy = sessions
            copy[i].title = title
            sessions = copy
        }
    }

    // MARK: - prompt

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if currentSessionID == nil {
            newSession()
        }
        guard let sid = currentSessionID else { return }
        let body: [String: Any] = [
            "agent": selectedAgent,
            "model": ["providerID": "opencode", "modelID": selectedModel],
            "parts": [["type": "text", "text": text]]
        ]
        let (status, _) = engine.handle(method: "POST", path: "/session/\(sid)/prompt_async",
                                        body: jsonText(body))
        if status >= 400 {
            errorMessage = "Не удалось отправить сообщение (HTTP \(status))"
            return
        }
        busy = true
        errorMessage = nil
    }

    func abort() {
        guard let sid = currentSessionID else { return }
        _ = engine.handle(method: "POST", path: "/session/\(sid)/abort", body: "{}")
        busy = false
    }

    func setModel(_ id: String) {
        selectedModel = id
        UserDefaults.standard.set(id, forKey: "ocm.native.model")
    }

    func setAgent(_ name: String) {
        selectedAgent = name
        UserDefaults.standard.set(name, forKey: "ocm.native.agent")
    }

    // MARK: - events

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }
        let props = event["properties"] as? [String: Any] ?? [:]
        let sid = props["sessionID"] as? String

        switch type {
        case "session.created", "session.updated":
            if let info = props["info"] as? [String: Any] {
                upsertSession(info)
            }
        case "session.deleted":
            if let info = props["info"] as? [String: Any], let id = info["id"] as? String {
                var copy = sessions
                copy.removeAll { $0.id == id }
                sessions = copy
                if currentSessionID == id { openSession(sessions.first?.id) }
            }
        case "session.status":
            if let sid, sid == currentSessionID {
                let status = props["status"] as? [String: Any] ?? [:]
                let kind = status["type"] as? String ?? "idle"
                busy = kind != "idle"
                bumpScroll()
            }
        case "session.idle":
            if sid == nil || sid == currentSessionID {
                busy = false
                bumpScroll()
                refreshSoon()
            }
        case "session.error":
            if sid == nil || sid == currentSessionID {
                let err = props["error"] as? [String: Any] ?? [:]
                errorMessage = (err["data"] as? [String: Any])?["message"] as? String
                    ?? (err["name"] as? String)
                    ?? "Ошибка агента"
                busy = false
                bumpScroll()
            }
        case "message.updated":
            guard let info = props["info"] as? [String: Any],
                  let infoSession = info["sessionID"] as? String,
                  infoSession == currentSessionID,
                  let id = info["id"] as? String else { return }
            updateMessageInfo(id: id, info: info)
            bumpScroll()
        case "message.part.updated":
            guard let part = props["part"] as? [String: Any],
                  let psid = part["sessionID"] as? String, psid == currentSessionID,
                  let mid = part["messageID"] as? String else { return }
            upsertPart(part, messageID: mid)
            bumpScroll()
        case "message.part.delta":
            guard let psid = props["sessionID"] as? String, psid == currentSessionID,
                  let mid = props["messageID"] as? String,
                  let pid = props["partID"] as? String,
                  let delta = props["delta"] as? String else { return }
            if let mi = messages.firstIndex(where: { $0.id == mid }) {
                var copy = messages
                if let pi = copy[mi].parts.firstIndex(where: { $0.id == pid }) {
                    copy[mi].parts[pi].text += delta
                } else {
                    let kind: NativePart.Kind = (props["field"] as? String) == "reasoning" ? .reasoning : .text
                    copy[mi].parts.append(NativePart(id: pid, kind: kind, text: delta))
                }
                messages = copy
                bumpScroll()
            }
        case "todo.updated":
            if sid == currentSessionID {
                todos = props["todos"] as? [[String: Any]] ?? []
            }
        default:
            break
        }
    }

    private func upsertSession(_ info: [String: Any]) {
        guard let id = info["id"] as? String else { return }
        let title = info["title"] as? String ?? "Новая сессия"
        let time = info["time"] as? [String: Any] ?? [:]
        let updated = (time["updated"] as? NSNumber)?.int64Value ?? 0
        var copy = sessions
        if let i = copy.firstIndex(where: { $0.id == id }) {
            copy[i].title = title
            copy[i].updated = updated
        } else {
            copy.append(NativeSession(id: id, title: title, updated: updated))
        }
        copy.sort { $0.updated > $1.updated }
        sessions = copy
    }

    private func updateMessageInfo(id: String, info: [String: Any]) {
        let role = info["role"] as? String ?? "assistant"
        let parsed = message(from: info, parts: [])
        var copy = messages
        if let i = copy.firstIndex(where: { $0.id == id }) {
            copy[i].role = role
            copy[i].error = parsed.error
            copy[i].model = parsed.model
            copy[i].tokens = parsed.tokens
            copy[i].duration = parsed.duration
        } else {
            var msg = parsed
            msg.parts = []
            copy.append(msg)
        }
        messages = copy
    }

    private func upsertPart(_ dict: [String: Any], messageID: String) {
        guard let id = dict["id"] as? String else { return }
        let part = parsePart(dict)
        var copy = messages
        if let mi = copy.firstIndex(where: { $0.id == messageID }) {
            if let pi = copy[mi].parts.firstIndex(where: { $0.id == id }) {
                var merged = part
                if merged.text.isEmpty { merged.text = copy[mi].parts[pi].text }
                copy[mi].parts[pi] = merged
            } else {
                copy[mi].parts.append(part)
            }
        } else {
            var msg = NativeMessage(id: messageID, role: "assistant")
            msg.parts = [part]
            copy.append(msg)
        }
        messages = copy
    }

    private func bumpScroll() {
        scrollTick &+= 1
    }

    private func refreshSoon() {
        guard !refreshing, let sid = currentSessionID else { return }
        refreshing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MainActor.run {
                guard let self else { return }
                self.refreshing = false
                guard self.currentSessionID == sid else { return }
                self.reloadMessages(sid)
            }
        }
    }

    private func reloadMessages(_ sid: String) {
        let (status, obj) = engine.handle(method: "GET", path: "/session/\(sid)/message", body: "")
        guard status == 200, let list = obj as? [[String: Any]] else { return }
        let fresh = list.compactMap { item -> NativeMessage? in
            guard let info = item["info"] as? [String: Any],
                  let parts = item["parts"] as? [[String: Any]] else { return nil }
            return message(from: info, parts: parts)
        }
        if !fresh.isEmpty || messages.isEmpty {
            messages = fresh
            bumpScroll()
        }
    }

    // MARK: - parsing

    private func message(from info: [String: Any], parts: [[String: Any]]) -> NativeMessage {
        let id = info["id"] as? String ?? UUID().uuidString
        let role = info["role"] as? String ?? "assistant"
        var msg = NativeMessage(id: id, role: role)
        msg.parts = parts.map(parsePart)
        if let error = info["error"] as? [String: Any] {
            msg.error = (error["data"] as? [String: Any])?["message"] as? String
                ?? error["name"] as? String ?? "Ошибка"
        }
        if let provider = info["providerID"] as? String, let model = info["modelID"] as? String {
            msg.model = "\(provider)/\(model)"
        }
        if let tokens = info["tokens"] as? [String: Any] {
            msg.tokens = (tokens["input"] as? Int ?? 0) + (tokens["output"] as? Int ?? 0)
                + (tokens["reasoning"] as? Int ?? 0)
        }
        let time = info["time"] as? [String: Any] ?? [:]
        let created = (time["created"] as? NSNumber)?.doubleValue ?? 0
        let completed = (time["completed"] as? NSNumber)?.doubleValue ?? 0
        if created > 0 && completed > created {
            msg.duration = (completed - created) / 1000.0
        }
        return msg
    }

    private func parsePart(_ p: [String: Any]) -> NativePart {
        let id = p["id"] as? String ?? UUID().uuidString
        let type = p["type"] as? String ?? "other"
        if type == "text" {
            return NativePart(id: id, kind: .text, text: p["text"] as? String ?? "")
        }
        if type == "reasoning" {
            return NativePart(id: id, kind: .reasoning, text: p["text"] as? String ?? "")
        }
        if type == "tool" {
            let state = p["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            var part = NativePart(id: id, kind: .tool)
            part.toolName = p["tool"] as? String ?? "tool"
            part.status = state["status"] as? String ?? ""
            part.output = state["output"] as? String ?? ""
            part.inputSummary = summary(tool: part.toolName, input: input)
            if let meta = state["metadata"] as? [String: Any], let diff = meta["diff"] as? String {
                part.diff = diff
            }
            if let error = state["error"] as? String { part.error = error }
            return part
        }
        if type == "file" {
            return NativePart(id: id, kind: .other, text: p["filename"] as? String ?? "файл")
        }
        if type == "patch" {
            let files = (p["files"] as? [[String: Any]])?.count ?? 0
            return NativePart(id: id, kind: .other, text: "Изменено файлов: \(files)")
        }
        return NativePart(id: id, kind: .other, text: type)
    }

    private func summary(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "bash": return input["command"] as? String ?? ""
        case "read", "write", "edit", "delete": return input["filePath"] as? String ?? ""
        case "list": return input["path"] as? String ?? "."
        case "grep": return input["pattern"] as? String ?? ""
        case "glob": return input["pattern"] as? String ?? ""
        case "webfetch": return input["url"] as? String ?? ""
        case "todowrite": return "задачи"
        default: return ""
        }
    }
}