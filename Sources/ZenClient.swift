import Foundation

struct ZenModel {
    let id: String
    let name: String
    let context: Int
    let maxOutput: Int
    let free: Bool
    let tools: Bool
    let reasoning: Bool

    var ui: [String: Any] {
        [
            "id": id,
            "name": name,
            "limit": ["context": context, "output": maxOutput],
            "cost": ["input": free ? 0 : 1, "output": free ? 0 : 1],
            "capabilities": ["toolcall": tools, "reasoning": reasoning],
            "attachment": false
        ]
    }
}

struct ZenToolCall {
    let id: String
    let name: String
    let arguments: String
}

struct ZenResult {
    var text = ""
    var reasoning = ""
    var toolCalls: [ZenToolCall] = []
    var usage: [String: Any] = [:]
    var cost: Double = 0
}

struct ZenError: Error {
    let status: Int
    let message: String
    var isQuota: Bool {
        message.lowercased().contains("free usage") ||
        message.lowercased().contains("quota") ||
        message.lowercased().contains("limit") ||
        status == 429
    }
}

final class ZenClient {
    static let shared = ZenClient()

    private let payBase = "https://opencode.ai/inference/openai/v1"
    private let goBase = "https://opencode.ai/inference/go/openai/v1"
    private let userAgent = "opencode/1.19.5 ai-sdk/provider-utils/4.0.23 runtime/bun/1.4.4"
    private let console = "https://opencode.ai/console"
    private let config = ServerConfig.shared
    private let lock = NSRecursiveLock()
    private var deviceTask: Task<Void, Never>?
    private var pollInterval: UInt64 = 5
    private var catalog: [ZenModel] = ZenClient.fallbackModels

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 900
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    var onAuthEvent: (([String: Any]) -> Void)?
    private let counterLock = NSLock()
    private var requestCounter = 0
    private var lastRequest = "—"

    var modelRequestCount: Int {
        counterLock.lock(); defer { counterLock.unlock() }
        return requestCounter
    }

    var lastRequestInfo: String {
        counterLock.lock(); defer { counterLock.unlock() }
        return lastRequest
    }

    private func record(status: Int, model: String, note: String = "") {
        counterLock.lock()
        requestCounter += 1
        lastRequest = "\(model) · HTTP \(status)" + (note.isEmpty ? "" : " · \(note)")
        counterLock.unlock()
    }

    static let fallbackModels: [ZenModel] = [
        ZenModel(id: "big-pickle", name: "Big Pickle", context: 200_000, maxOutput: 32_000, free: true, tools: true, reasoning: true),
        ZenModel(id: "beam-free", name: "Beam Free", context: 1_048_576, maxOutput: 131_072, free: true, tools: true, reasoning: true),
        ZenModel(id: "flint-40b-free", name: "Flint 40B Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        ZenModel(id: "deepseek-v4.1-flash-free", name: "DeepSeek V4.1 Flash Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        ZenModel(id: "glm-5.3-flash-free", name: "GLM-5.3 Flash Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        ZenModel(id: "mimo-v2.6-flash-free", name: "MiMo V2.6 Flash Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        ZenModel(id: "nemotron-3.5-lightning-free", name: "Nemotron 3.5 Lightning Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        ZenModel(id: "nemotron-3.5-super-vl-free", name: "Nemotron 3.5 Super VL Free", context: 262_144, maxOutput: 65_536, free: true, tools: true, reasoning: true),
        // Paid fallbacks are available as soon as an API key or Console login exists.
        ZenModel(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", context: 1_000_000, maxOutput: 128_000, free: false, tools: true, reasoning: true),
        ZenModel(id: "deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", context: 1_000_000, maxOutput: 384_000, free: false, tools: true, reasoning: true),
        ZenModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", context: 200_000, maxOutput: 64_000, free: false, tools: true, reasoning: true),
        ZenModel(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", context: 200_000, maxOutput: 64_000, free: false, tools: true, reasoning: true),
        ZenModel(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", context: 1_000_000, maxOutput: 128_000, free: false, tools: true, reasoning: true),
        ZenModel(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", context: 1_048_576, maxOutput: 65_536, free: false, tools: true, reasoning: true),
        ZenModel(id: "glm-5.3", name: "GLM-5.3", context: 1_000_000, maxOutput: 131_072, free: false, tools: true, reasoning: true),
        ZenModel(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", context: 262_144, maxOutput: 262_144, free: false, tools: true, reasoning: true)
    ]

    private init() {}

    var models: [ZenModel] {
        lock.lock(); defer { lock.unlock() }
        return catalog
    }

    var isLoggedIn: Bool {
        !config.zenAccess.isEmpty || !config.zenRefresh.isEmpty
    }

    var hasKey: Bool { !config.zenKey.isEmpty }

    var accountEmail: String? {
        if isLoggedIn { return config.zenEmail.isEmpty ? "аккаунт OpenCode" : config.zenEmail }
        if hasKey { return "API-ключ OpenCode" }
        return nil
    }

    var anonymous: Bool { !isLoggedIn && !hasKey }

    func model(_ id: String) -> ZenModel? {
        models.first { $0.id == id }
    }

    /// Models the app can actually call right now.
    /// Free models are restricted by Console to the official OpenCode client, so an
    /// authenticated third-party harness must use paid models only.
    var selectableModels: [ZenModel] {
        // Free models are available through the BoringSSL/Bun transport;
        // paid models need a key or Console login.
        if anonymous { return models.filter { $0.free } }
        return models
    }

    func defaultModel() -> String {
        let list = selectableModels
        if let m = model(config.zenModel), list.contains(where: { $0.id == m.id }) {
            return m.id
        }
        if !anonymous {
            for id in ["gpt-5.6-luna", "deepseek-v4.1-flash", "claude-haiku-5-5", "claude-sonnet-4-5", "gpt-5.6-sol"] {
                if let m = list.first(where: { $0.id == id }) { return m.id }
            }
            if let paid = list.first { return paid.id }
        }
        if let p = list.first(where: { $0.id == "big-pickle" }) { return p.id }
        return list.first?.id ?? ""
    }

    private var baseCandidates: [String] {
        guard hasKey else { return [payBase] }
        var list = [payBase, goBase]
        let saved = config.zenBase
        if !saved.isEmpty, list.contains(saved) {
            list.removeAll { $0 == saved }
            list.insert(saved, at: 0)
        }
        return list
    }

    private func applyAuth(_ req: inout URLRequest, token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // x-org-id belongs to the OAuth Console credential; a personal API key
        // already selects its workspace and must not inherit another org scope.
        if !hasKey, !config.zenOrgID.isEmpty {
            req.setValue(config.zenOrgID, forHTTPHeaderField: "x-org-id")
        }
    }

    // MARK: - catalog

    func refreshCatalog() async {
        guard let url = URL(string: "https://opencode.ai/inference/v1/models") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rows = obj["data"] as? [[String: Any]] else { return }
            var parsed: [ZenModel] = []
            for row in rows {
                guard let id = row["id"] as? String,
                      (row["type"] as? String ?? "chat") == "chat" else { continue }
                let name = row["name"] as? String ?? id
                let limit = row["limit"] as? [String: Any] ?? [:]
                let context = limit["context"] as? Int ?? 128_000
                let output = limit["output"] as? Int ?? 32_000
                let cost = row["cost"] as? [String: Any] ?? [:]
                let textCost = cost["text"] as? [String: Any] ?? [:]
                let input = textCost["input"] as? [String: Any] ?? [:]
                let outCost = textCost["output"] as? [String: Any] ?? [:]
                let priceIn = input["price"] as? Double ?? Double(input["price"] as? Int ?? 1)
                let priceOut = outCost["price"] as? Double ?? Double(outCost["price"] as? Int ?? 1)
                let caps = row["capabilities"] as? [String: Any] ?? [:]
                let tools = (caps["tools"] as? [String: Any])?["supported"] as? Bool ?? false
                let reasoning = (caps["reasoning"] as? [String: Any])?["supported"] as? Bool ?? false
                parsed.append(ZenModel(id: id, name: name, context: context, maxOutput: output,
                                       free: priceIn == 0 && priceOut == 0, tools: tools, reasoning: reasoning))
            }
            if !parsed.isEmpty {
                lock.lock()
                catalog = parsed
                lock.unlock()
            }
        } catch {
            // offline: fallback list stays
        }
    }

    // MARK: - auth / token

    private func basicJSON(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private func parseError(_ data: Data, status: Int) -> ZenError {
        var message = "HTTP \(status)"
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let err = obj["error"] as? [String: Any] {
                message = err["message"] as? String ?? err["type"] as? String ?? message
            } else if let msg = obj["message"] as? String {
                message = msg
            }
        }
        return ZenError(status: status, message: message)
    }

    func currentToken() async -> String {
        // A pasted API key is an explicit choice and always wins over a stale
        // or free Console OAuth session.
        if hasKey { return config.zenKey }
        if isLoggedIn {
            let expiry = config.zenExpiry
            if expiry == 0 || expiry > Date().timeIntervalSince1970 + 60 {
                if !config.zenAccess.isEmpty { return config.zenAccess }
            }
            if let refreshed = await refreshToken() { return refreshed }
        }
        return "public"
    }

    private func refreshToken() async -> String? {
        guard !config.zenRefresh.isEmpty else { return nil }
        guard let url = URL(string: console + "/auth/device/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = basicJSON([
            "grant_type": "refresh_token",
            "refresh_token": config.zenRefresh,
            "client_id": "opencode-cli"
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = obj["access_token"] as? String else { return nil }
            config.zenAccess = access
            if let refresh = obj["refresh_token"] as? String { config.zenRefresh = refresh }
            if let org = obj["org_id"] as? String { config.zenOrgID = org }
            if let expires = obj["expires_in"] as? Double {
                config.zenExpiry = Date().timeIntervalSince1970 + expires
            }
            return access
        } catch {
            return nil
        }
    }

    func startDeviceLogin() {
        cancelLogin()
        deviceTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = URL(string: self.console + "/auth/device/code") else { return }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = self.basicJSON(["client_id": "opencode-cli", "supports_org_scope": true])
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let deviceCode = obj["device_code"] as? String,
                      let userCode = obj["user_code"] as? String else {
                    self.emitAuth(["stage": "error", "error": "Не удалось получить код входа"])
                    return
                }
                let interval = obj["interval"] as? UInt64 ?? 5
                self.pollInterval = max(3, interval)
                let relative = obj["verification_uri_complete"] as? String ?? "/console/device?user_code=\(userCode)"
                let full = relative.hasPrefix("http") ? relative : "https://opencode.ai" + relative
                self.emitAuth(["stage": "url", "url": full, "code": userCode])

                var waited: UInt64 = 0
                let expires = UInt64((obj["expires_in"] as? Int ?? 600))
                while !Task.isCancelled && waited < expires {
                    try await Task.sleep(nanoseconds: self.pollInterval * 1_000_000_000)
                    waited += self.pollInterval
                    if Task.isCancelled { return }
                    var poll = URLRequest(url: URL(string: self.console + "/auth/device/token")!)
                    poll.httpMethod = "POST"
                    poll.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    poll.httpBody = self.basicJSON([
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "device_code": deviceCode,
                        "client_id": "opencode-cli"
                    ])
                    let (pdata, presp) = try await URLSession.shared.data(for: poll)
                    guard let phttp = presp as? HTTPURLResponse else { continue }
                    let pobj = (try? JSONSerialization.jsonObject(with: pdata)) as? [String: Any] ?? [:]
                    if let access = pobj["access_token"] as? String {
                        self.config.zenAccess = access
                        self.config.zenBase = ""
                        if let refresh = pobj["refresh_token"] as? String { self.config.zenRefresh = refresh }
                        if let org = pobj["org_id"] as? String { self.config.zenOrgID = org }
                        if let exp = pobj["expires_in"] as? Double {
                            self.config.zenExpiry = Date().timeIntervalSince1970 + exp
                        } else if let exp = pobj["expires_in"] as? Int {
                            self.config.zenExpiry = Date().timeIntervalSince1970 + Double(exp)
                        }
                        let email = await self.fetchEmail(access: access)
                        self.config.zenEmail = email
                        self.emitAuth(["stage": "done", "email": email, "synced": true])
                        return
                    }
                    let code = pobj["error"] as? String ?? ""
                    if code == "slow_down" {
                        self.pollInterval += 5
                    } else if code == "access_denied" {
                        self.emitAuth(["stage": "error", "error": "Вход отклонён"])
                        return
                    } else if code == "expired_token" {
                        self.emitAuth(["stage": "error", "error": "Код входа истёк. Попробуйте ещё раз"])
                        return
                    } else if phttp.statusCode >= 400 && code.isEmpty {
                        self.emitAuth(["stage": "error", "error": "Ошибка входа (HTTP \(phttp.statusCode))"])
                        return
                    }
                }
                if !Task.isCancelled {
                    self.emitAuth(["stage": "error", "error": "Время ожидания входа истекло"])
                }
            } catch {
                if !Task.isCancelled {
                    self.emitAuth(["stage": "error", "error": shortError(error)])
                }
            }
        }
    }

    func cancelLogin() {
        deviceTask?.cancel()
        deviceTask = nil
    }

    func logout() {
        cancelLogin()
        config.zenAccess = ""
        config.zenRefresh = ""
        config.zenExpiry = 0
        config.zenEmail = ""
        config.zenOrgID = ""
        config.zenBase = ""
        config.zenKey = ""
    }

    private func fetchEmail(access: String) async -> String {
        guard let url = URL(string: console + "/api/user") else { return "аккаунт OpenCode" }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let email = obj["email"] as? String, !email.isEmpty {
            return email
        }
        return "аккаунт OpenCode"
    }

    private func emitAuth(_ payload: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onAuthEvent?(payload) }
    }

    /// A user-triggered minimal request that tries both Console gateways.
    func probeFreeAccess() async -> String {
        let model = defaultModel().isEmpty ? "big-pickle" : defaultModel()
        let token = (self.model(model)?.free ?? false) ? "public" : await currentToken()
        var reports: [String] = []
        for base in baseCandidates {
            guard let url = URL(string: base + "/chat/completions") else {
                reports.append("Некорректный URL")
                continue
            }
            let body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
                "stream": false
            ]
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(&req, token: token)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let sid = newSessionID()
            req.setValue(sid, forHTTPHeaderField: "x-opencode-session-id")
            req.setValue(sid, forHTTPHeaderField: "x-opencode-session")
            req.setValue("cli", forHTTPHeaderField: "x-opencode-client")
            req.setValue("global", forHTTPHeaderField: "x-opencode-project")
            req.setValue(newID("msg_"), forHTTPHeaderField: "x-opencode-request")
            req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            let label = base.contains("/go/") ? "OpenCode Go" : "Pay-as-you-go"
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                record(status: status, model: model, note: "probe")
                let text = String(decoding: data, as: UTF8.self)
                reports.append("\(label): HTTP \(status)\n\(String(text.prefix(900)))")
                if (200..<300).contains(status) {
                    config.zenBase = base
                    return reports.joined(separator: "\n\n")
                }
            } catch {
                record(status: 0, model: model, note: "probe error")
                reports.append("\(label): \(shortError(error))")
            }
        }
        return reports.joined(separator: "\n\n")
    }

    // MARK: - free transport

    /// Free Console models reject URLSession/WKWebView. The official client's
    /// Bun TLS ClientHello is reproduced by BoringTransport; this path sends
    /// the official free-agent body through it.
    private func streamFree(model: String,
                            sessionID: String?,
                            messages: [[String: Any]],
                            tools: [[String: Any]],
                            onDelta: @escaping (_ field: String, _ delta: String) -> Void) async throws -> ZenResult {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 32_000,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw ZenError(status: 0, message: "Не удалось собрать запрос")
        }
        if ProcessInfo.processInfo.environment["OCM_BORING_TEST"] == "1" {
            let path = AgentPaths.workspace.appendingPathComponent("boring-body.json")
            try? data.write(to: path)
        }
        let sid = sessionID ?? newSessionID()
        let headers: [String: String] = [
            "Authorization": "Bearer public",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "x-opencode-client": "cli",
            "x-opencode-project": "global",
            "x-opencode-request": newID("msg_"),
            "x-opencode-session": sid,
            "x-opencode-session-id": sid,
            "Accept": "*/*"
        ]
        guard let response = await BoringTransport.post(host: "opencode.ai",
                                                        path: "/inference/openai/v1/chat/completions",
                                                        headers: headers,
                                                        body: data) else {
            record(status: 0, model: model, note: "boring-free")
            throw ZenError(status: 0, message: "Не удалось открыть TLS-соединение с Console")
        }
        record(status: response.status, model: model, note: "boring-free")
        guard (200..<300).contains(response.status) else {
            throw parseError(response.body, status: response.status)
        }
        return try parseSSEData(response.body, status: response.status, onDelta: onDelta)
    }

    private func parseSSEData(_ data: Data,
                              status: Int,
                              onDelta: @escaping (_ field: String, _ delta: String) -> Void) throws -> ZenResult {
        let text = String(decoding: data, as: UTF8.self)
        var result = ZenResult()
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var usage: [String: Any] = [:]
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? err["type"] as? String ?? "Ошибка модели"
                throw ZenError(status: status, message: msg)
            }
            if let u = obj["usage"] as? [String: Any] {
                usage = u
                if let c = u["cost"] as? Double { result.cost = c }
                else if let c = u["cost"] as? Int { result.cost = Double(c) }
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            let delta = first["delta"] as? [String: Any] ?? [:]
            if let t = delta["content"] as? String, !t.isEmpty {
                result.text += t
                onDelta("text", t)
            }
            if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                result.reasoning += r
                onDelta("reasoning", r)
            } else if let r = delta["reasoning"] as? String, !r.isEmpty {
                result.reasoning += r
                onDelta("reasoning", r)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    let idx = tc["index"] as? Int ?? 0
                    var cur = calls[idx] ?? ("", "", "")
                    if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { cur.name += n }
                        if let a = fn["arguments"] as? String { cur.args += a }
                    }
                    calls[idx] = cur
                }
            }
        }
        if !usage.isEmpty {
            var tokens: [String: Any] = [
                "input": usage["prompt_tokens"] as? Int ?? 0,
                "output": usage["completion_tokens"] as? Int ?? 0,
                "reasoning": 0,
                "cache": ["read": 0, "write": 0]
            ]
            if let opencode = usage["opencode"] as? [String: Any],
               let t = opencode["tokens"] as? [String: Any] {
                tokens["reasoning"] = t["reasoning"] as? Int ?? 0
                tokens["cache"] = [
                    "read": t["cache_read"] as? Int ?? 0,
                    "write": t["cache_write_5m"] as? Int ?? 0
                ]
            }
            result.usage = tokens
        }
        result.toolCalls = calls.keys.sorted().compactMap { idx in
            guard let c = calls[idx], !c.name.isEmpty else { return nil }
            return ZenToolCall(id: c.id.isEmpty ? newID("call_") : c.id, name: c.name, arguments: c.args)
        }
        return result
    }

    // MARK: - streaming chat

    func stream(model: String,
                sessionID: String? = nil,
                messages: [[String: Any]],
                tools: [[String: Any]],
                onDelta: @escaping (_ field: String, _ delta: String) -> Void) async throws -> ZenResult {
        let effectiveModel = model
        let isFreeModel = self.model(effectiveModel)?.free ?? false
        // Console's free tier is anonymous: the official client sends
        // `Bearer public`, not the user's paid API key.
        if isFreeModel {
            return try await streamFree(model: effectiveModel, sessionID: sessionID, messages: messages, tools: tools, onDelta: onDelta)
        }
        let token = await currentToken()
        let candidates = baseCandidates
        var primary: ZenError?
        for (index, base) in candidates.enumerated() {
            do {
                let result = try await streamOnce(base: base, token: token, model: effectiveModel,
                                                  sessionID: sessionID, messages: messages,
                                                  tools: tools, onDelta: onDelta)
                if config.zenBase != base { config.zenBase = base }
                return result
            } catch let error as ZenError {
                if index == 0 { primary = error }
                // A Go key at the pay-as-you-go URL and vice versa gives a
                // misleading quota/auth response. Try the other gateway once.
                if index + 1 < candidates.count, [401, 402, 403, 429].contains(error.status) {
                    continue
                }
                throw primary ?? error
            } catch {
                if let primary { throw primary }
                throw error
            }
        }
        throw primary ?? ZenError(status: 0, message: "Нет доступного шлюза OpenCode")
    }

    // MARK: - streaming chat

    private func streamOnce(base: String,
                            token: String,
                            model: String,
                            sessionID: String? = nil,
                            messages: [[String: Any]],
                            tools: [[String: Any]],
                            onDelta: @escaping (_ field: String, _ delta: String) -> Void) async throws -> ZenResult {
        guard let url = URL(string: base + "/chat/completions") else {
            throw ZenError(status: 0, message: "Некорректный адрес API")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 32_000,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(&req, token: token)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let sid = sessionID ?? newSessionID()
        req.setValue(sid, forHTTPHeaderField: "x-opencode-session-id")
        req.setValue(sid, forHTTPHeaderField: "x-opencode-session")
        req.setValue("cli", forHTTPHeaderField: "x-opencode-client")
        req.setValue("global", forHTTPHeaderField: "x-opencode-project")
        req.setValue(newID("msg_"), forHTTPHeaderField: "x-opencode-request")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            record(status: 0, model: model, note: "no response")
            throw ZenError(status: 0, message: "Нет ответа от API")
        }
        record(status: http.statusCode, model: model)
        if !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 32_000 { break }
            }
            throw parseError(data, status: http.statusCode)
        }

        var result = ZenResult()
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var usage: [String: Any] = [:]

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw == "[DONE]" { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { continue }

            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? err["type"] as? String ?? "Ошибка модели"
                throw ZenError(status: http.statusCode, message: msg)
            }
            if let u = obj["usage"] as? [String: Any] {
                usage = u
                if let c = u["cost"] as? Double { result.cost = c }
                else if let c = u["cost"] as? Int { result.cost = Double(c) }
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }
            let delta = first["delta"] as? [String: Any] ?? [:]
            if let text = delta["content"] as? String, !text.isEmpty {
                result.text += text
                onDelta("text", text)
            }
            if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                result.reasoning += r
                onDelta("reasoning", r)
            } else if let r = delta["reasoning"] as? String, !r.isEmpty {
                result.reasoning += r
                onDelta("reasoning", r)
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = tc["index"] as? Int ?? 0
                    var cur = calls[idx] ?? ("", "", "")
                    if let id = tc["id"] as? String, !id.isEmpty { cur.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { cur.name += n }
                        if let a = fn["arguments"] as? String { cur.args += a }
                    }
                    calls[idx] = cur
                }
            }
        }

        if !usage.isEmpty {
            var tokens: [String: Any] = [
                "input": usage["prompt_tokens"] as? Int ?? 0,
                "output": usage["completion_tokens"] as? Int ?? 0,
                "reasoning": 0,
                "cache": ["read": 0, "write": 0]
            ]
            if let opencode = usage["opencode"] as? [String: Any],
               let t = opencode["tokens"] as? [String: Any] {
                tokens["reasoning"] = t["reasoning"] as? Int ?? 0
                tokens["cache"] = [
                    "read": t["cache_read"] as? Int ?? 0,
                    "write": t["cache_write_5m"] as? Int ?? 0
                ]
            }
            result.usage = tokens
        }

        result.toolCalls = calls.keys.sorted().compactMap { idx in
            guard let c = calls[idx], !c.name.isEmpty else { return nil }
            return ZenToolCall(id: c.id.isEmpty ? newID("call_") : c.id, name: c.name, arguments: c.args)
        }
        return result
    }
}