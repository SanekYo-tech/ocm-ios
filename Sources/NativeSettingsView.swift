import SwiftUI
import UIKit
import UserNotifications

struct NativeSettingsView: View {
    @EnvironmentObject var chat: NativeChatStore
    @StateObject private var account = NativeAccountModel()
    @AppStorage("ocm.notifications") private var notifications = false

    var body: some View {
        NavigationStack {
            List {
                Section("Аккаунт") {
                    NavigationLink {
                        AccountView(account: account)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(OCTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.email ?? "Не выполнен вход")
                                    .font(.system(size: 14, weight: .medium))
                                Text(account.subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(OCTheme.muted)
                            }
                        }
                    }
                }

                Section("Модель") {
                    NavigationLink {
                        ModelPickerView(store: chat)
                    } label: {
                        HStack {
                            Label("Модель", systemImage: "cpu")
                            Spacer()
                            Text(chat.models.first(where: { $0.id == chat.selectedModel })?.name ?? chat.selectedModel)
                                .foregroundStyle(OCTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Label("Агент", systemImage: "hammer")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { chat.selectedAgent },
                            set: { chat.setAgent($0) }
                        )) {
                            Text("build").tag("build")
                            Text("plan").tag("plan")
                        }
                        .labelsHidden()
                        .tint(OCTheme.muted)
                    }
                }

                Section("Конфигурация") {
                    NavigationLink {
                        ConfigEditorView()
                    } label: {
                        Label("config.json", systemImage: "curlybraces")
                    }
                    HStack {
                        Label("Workspace", systemImage: "folder")
                        Spacer()
                        Text("OpenCode")
                            .foregroundStyle(OCTheme.muted)
                    }
                    Text(AgentPaths.workspace.path)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(OCTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Section("Уведомления") {
                    Toggle(isOn: Binding(
                        get: { notifications },
                        set: { value in
                            notifications = value
                            if value { requestNotifications() }
                        }
                    )) {
                        Label("Завершение задач", systemImage: "bell")
                    }
                }

                Section("Диагностика") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Проверка shell / Python / Git", systemImage: "stethoscope")
                    }
                }

                Section("О приложении") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("OpenCode iOS", systemImage: "info.circle")
                    }
                    Link(destination: URL(string: "https://opencode.ai")!) {
                        Label("opencode.ai", systemImage: "globe")
                    }
                }

                Section {
                    Text("Бесплатные модели OpenCode Zen пробуются автоматически. Если серверная квота исчерпана — войди в аккаунт или добавь API-ключ. Git и Python (beta) работают на устройстве.")
                        .font(.system(size: 12))
                        .foregroundStyle(OCTheme.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(OCTheme.bg)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(OCTheme.accent)
        .onAppear { account.refresh() }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            UserDefaults.standard.set(granted, forKey: "ocm.notifications")
        }
    }
}

@MainActor
final class NativeAccountModel: ObservableObject {
    @Published var email: String?
    @Published var stage: String = "idle"
    @Published var authURL: String?
    @Published var code: String?
    @Published var error: String?
    @Published var hasKey = false
    private let zen = ZenClient.shared

    init() {
        zen.onAuthEvent = { [weak self] event in
            Task { [weak self] in
                await MainActor.run { self?.handle(event) }
            }
        }
        refresh()
    }

    var subtitle: String {
        if let email, !email.isEmpty { return email }
        if hasKey { return "API-ключ" }
        return "Бесплатный режим · вход не требуется"
    }

    func refresh() {
        email = zen.accountEmail
        hasKey = zen.hasKey
    }

    func startLogin() {
        error = nil
        code = nil
        authURL = nil
        stage = "loading"
        zen.startDeviceLogin()
    }

    func cancel() {
        zen.cancelLogin()
        stage = "idle"
    }

    func logout() {
        zen.logout()
        stage = "idle"
        refresh()
    }

    func saveKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        ServerConfig.shared.zenAccess = ""
        ServerConfig.shared.zenRefresh = ""
        ServerConfig.shared.zenEmail = ""
        ServerConfig.shared.zenOrgID = ""
        ServerConfig.shared.zenKey = key
        refresh()
        error = nil
    }

    private func handle(_ event: [String: Any]) {
        switch event["stage"] as? String {
        case "url":
            authURL = event["url"] as? String
            code = event["code"] as? String
            stage = "waiting"
            if let authURL, let url = URL(string: authURL) {
                UIApplication.shared.open(url)
            }
        case "done":
            email = event["email"] as? String
            stage = "done"
            refresh()
            error = nil
        case "error":
            error = event["error"] as? String
            stage = "error"
        default:
            break
        }
    }
}

struct AccountView: View {
    @ObservedObject var account: NativeAccountModel
    @State private var key = ""
    @State private var showKey = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(OCTheme.bg3).frame(width: 52, height: 52)
                        Image(systemName: account.email == nil ? "person" : "person.fill.checkmark")
                            .font(.system(size: 21))
                            .foregroundStyle(OCTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.email ?? "Бесплатный режим")
                            .font(.system(size: 16, weight: .semibold))
                        Text(account.email == nil ? "Можно войти, чтобы получить личную квоту" : "Квота OpenCode Zen привязана к аккаунту")
                            .font(.system(size: 12))
                            .foregroundStyle(OCTheme.muted)
                    }
                }
                .padding(.vertical, 6)
            }

            if account.stage == "waiting" || account.stage == "loading" {
                Section {
                    if let code = account.code {
                        VStack(spacing: 12) {
                            Text("Код входа")
                                .font(.system(size: 12))
                                .foregroundStyle(OCTheme.muted)
                            Text(code)
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .tracking(3)
                                .foregroundStyle(OCTheme.accent)
                            if let authURL = account.authURL, let url = URL(string: authURL) {
                                Button {
                                    UIApplication.shared.open(url)
                                } label: {
                                    Label("Открыть страницу входа", systemImage: "safari")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(OCTheme.accent)
                            }
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Ожидаем подтверждение в браузере")
                                    .font(.system(size: 12))
                                    .foregroundStyle(OCTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().tint(OCTheme.accent)
                            Text("Готовим код входа…").foregroundStyle(OCTheme.muted)
                        }
                    }
                    Button("Отменить", role: .cancel) { account.cancel() }
                }
            } else if account.stage == "done" {
                Section {
                    Label("Вход выполнен", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(OCTheme.green)
                }
            } else {
                Section {
                    Button {
                        account.startLogin()
                    } label: {
                        Label("Войти через Google / GitHub", systemImage: "person.badge.key")
                    }
                    Text("Откроется opencode.ai. Выбери Google или GitHub, подтверди вход — код уже будет подставлен.")
                        .font(.system(size: 12))
                        .foregroundStyle(OCTheme.muted)
                }
                Section("Свой API-ключ OpenCode Console") {
                    if showKey {
                        SecureField("ocp_…", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Сохранить ключ") {
                            account.saveKey(key)
                            key = ""
                            showKey = false
                        }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Ввести API-ключ") { showKey = true }
                    }
                }
            }

            if let error = account.error {
                Section {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(OCTheme.red)
                }
            }

            if account.email != nil || account.hasKey {
                Section {
                    Button("Выйти", role: .destructive) {
                        account.logout()
                    }
                }
            }

            Section {
                Text("Бесплатные модели работают через анонимный режим OpenCode. Серверная квота может быть исчерпана — это не ошибка приложения. Вход или ключ дают личный лимит.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(OCTheme.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(OCTheme.bg)
        .navigationTitle("Аккаунт opencode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { account.refresh() }
    }
}

struct ConfigEditorView: View {
    @State private var text = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            OCTheme.bg.ignoresSafeArea()
            if loaded {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OCTheme.text)
                    .scrollContentBackground(.hidden)
                    .background(OCTheme.bg)
                    .padding(.horizontal, 10)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                ProgressView().tint(OCTheme.accent)
            }
        }
        .navigationTitle("config.json")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сохранить") { save() }
                    .fontWeight(.semibold)
            }
        }
        .alert("Ошибка", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("Закрыть", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .overlay(alignment: .top) {
            if saved {
                Text("Сохранено")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OCTheme.green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(cornerRadius: 14)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        if let value = try? String(contentsOf: AgentPaths.userConfigFile, encoding: .utf8) {
            text = value
        } else {
            text = "{\n  \"$schema\": \"https://opencode.ai/config.json\",\n  \"model\": \"opencode/big-pickle\"\n}\n"
        }
        loaded = true
    }

    private func save() {
        guard let data = stripJSONC(text).data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else {
            error = "Неверный JSON"
            return
        }
        do {
            try text.write(to: AgentPaths.userConfigFile, atomically: true, encoding: .utf8)
            AgentEngine.shared.reloadConfig()
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { saved = false }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DiagnosticsView: View {
    @State private var output = ""
    @State private var busy = false

    private var requestInfo: String {
        let zen = ZenClient.shared
        let mode: String
        if zen.isLoggedIn { mode = "аккаунт OpenCode" }
        else if zen.hasKey { mode = "API-ключ" }
        else { mode = "анонимный public" }
        return "Модельных запросов с запуска: \(zen.modelRequestCount)\nРежим: \(mode)\nПоследний: \(zen.lastRequestInfo)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Проверка локального окружения. Python загружается динамически: если рантайм не подходит устройству, вы получите ошибку, а не вылет.")
                    .font(.system(size: 12))
                    .foregroundStyle(OCTheme.muted)

                Text(requestInfo)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OCTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(OCTheme.bg2, in: RoundedRectangle(cornerRadius: 10))

                VStack(spacing: 8) {
                    diagButton("Проверить бесплатный доступ (1 запрос)", command: "__probe__")
                    diagButton("Shell: pwd + ls", command: "pwd; echo ---; ls -la")
                    diagButton("Python: 6 × 7 (beta)", command: "python3 -c \"print(6*7)\"")
                    diagButton("Python: версия (beta)", command: "python3 -c \"import sys; print(sys.version)\"")
                    diagButton("Git: --version", command: "git --version")
                }

                if busy {
                    HStack(spacing: 8) {
                        ProgressView().tint(OCTheme.accent)
                        Text("Выполняется…").foregroundStyle(OCTheme.muted)
                    }
                }

                Text(output.isEmpty ? "Результат появится здесь" : output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OCTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OCTheme.code, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(14)
        }
        .background(OCTheme.bg)
        .navigationTitle("Диагностика")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func diagButton(_ title: String, command: String) -> some View {
        Button {
            run(command)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OCTheme.accent)
            }
            .foregroundStyle(OCTheme.text)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(OCTheme.bg2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(OCTheme.line, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func run(_ command: String) {
        guard !busy else { return }
        busy = true
        if command == "__probe__" {
            output += "\n> проверка OpenCode Zen (реальный запрос, 1 токен)\n"
            Task {
                let result = await ZenClient.shared.probeFreeAccess()
                await MainActor.run {
                    output += result + "\n"
                    busy = false
                }
            }
            return
        }
        output += "\n$ \(command)\n"
        Task.detached(priority: .userInitiated) {
            let result = ShellRunner.shared.run(command, cwd: AgentPaths.workspace.path, timeout: 60)
            await MainActor.run {
                output += result.output
                if !result.output.hasSuffix("\n") { output += "\n" }
                if result.code != 0 { output += "[код \(result.code)]\n" }
                busy = false
            }
        }
    }
}

struct AboutView: View {
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    OpenCodeMark(size: 48)
                    Text("OpenCode iOS")
                        .font(.system(size: 20, weight: .semibold))
                    Text("v\(version) · on-device agent")
                        .font(.system(size: 12))
                        .foregroundStyle(OCTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                Text("Локальный workspace, AI-агент, Unix-терминал ios_system, git через libgit2 и Python 3.9. Всё работает на iPhone; компьютер нужен только для подписи IPA.")
                    .font(.system(size: 13))
            }
            Section("Ограничения iOS") {
                Text("Нет Node.js/npm и компиляторов. Python beta без pip/ssl/sqlite3. Git поддерживает init/status/add/commit/log/diff/branch/checkout; pull/push пока нет.")
                    .font(.system(size: 12))
                    .foregroundStyle(OCTheme.muted)
            }
            Section {
                Link("OpenCode", destination: URL(string: "https://opencode.ai")!)
                Link("ios_system / a-Shell", destination: URL(string: "https://github.com/holzschu/ios_system")!)
            }
            Section {
            }
        }
        .scrollContentBackground(.hidden)
        .background(OCTheme.bg)
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
}