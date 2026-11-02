import SwiftUI

struct NativeChatView: View {
    @EnvironmentObject var store: NativeChatStore
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var showError = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                OCTheme.bg.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if store.messages.isEmpty {
                                emptyState
                            } else {
                                ForEach(store.messages) { message in
                                    MessageView(message: message)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: store.scrollTick) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: store.currentSessionID) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .navigationTitle(store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.showingSessions = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                    .tint(OCTheme.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if store.busy {
                            ProgressView().controlSize(.small).tint(OCTheme.accent)
                        }
                        Button {
                            store.newSession()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .tint(OCTheme.accent)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
            }
            .sheet(isPresented: $store.showingSessions) {
                SessionListView(store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $store.showingModels) {
                ModelPickerView(store: store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert(quotaError ? "Нужен вход" : "Ошибка", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                if quotaError {
                    Button("Войти") {
                        store.errorMessage = nil
                        showAccount = true
                    }
                }
                Button("Закрыть", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .sheet(isPresented: $showAccount) {
                NavigationStack {
                    AccountView(account: NativeAccountModel())
                }
            }
            .onAppear { store.bootstrap() }
        }
        .tint(OCTheme.accent)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 70)
            OpenCodeMark(size: 54)
                .padding(.bottom, 4)
            Text("OpenCode")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(OCTheme.text)
            Text(AgentPaths.workspace.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(OCTheme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 30)
            Text("Опиши задачу — агент прочитает файлы, выполнит команды и покажет изменения. Git и Python (beta) работают локально.")
                .font(.system(size: 14))
                .foregroundStyle(OCTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 8) {
                suggestion("Посмотри проект и предложи улучшения")
                suggestion("Создай новый файл и напиши небольшую программу")
                suggestion("Сделай git status и объясни изменения")
            }
            .padding(.top, 6)
            Spacer(minLength: 30)
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ title: String) -> some View {
        Button {
            text = title
            focused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OCTheme.accent)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(OCTheme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360)
            .background(OCTheme.bg2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(OCTheme.line, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    ForEach(["build", "plan"], id: \.self) { name in
                        Button {
                            store.setAgent(name)
                        } label: {
                            if store.selectedAgent == name {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer")
                            .font(.system(size: 10, weight: .semibold))
                        Text(store.selectedAgent)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(OCTheme.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(OCTheme.bg3, in: Capsule())
                }

                TextField("Спросите что угодно…", text: $text, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(OCTheme.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 4)

                Button {
                    if store.busy {
                        store.abort()
                    } else {
                        let value = text
                        text = ""
                        focused = false
                        store.send(value)
                    }
                } label: {
                    Image(systemName: store.busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(store.busy ? Color.white : Color.black)
                        .frame(width: 32, height: 32)
                        .background(store.busy ? OCTheme.red : OCTheme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.busy && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(!store.busy && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassSurface(cornerRadius: 20)

            HStack(spacing: 8) {
                Button {
                    store.showingModels = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                            .font(.system(size: 10, weight: .semibold))
                        Text(modelName)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(OCTheme.muted)
                }
                .buttonStyle(.plain)

                Spacer()

                if !store.todos.isEmpty {
                    let done = store.todos.filter { ($0["status"] as? String) == "completed" }.count
                    Text("\(done)/\(store.todos.count) задач")
                        .font(.system(size: 10.5))
                        .foregroundStyle(OCTheme.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 5)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .background(.clear)
    }

    private var quotaError: Bool {
        let text = (store.errorMessage ?? "").lowercased()
        return text.contains("квот") || text.contains("quota") || text.contains("лимит")
    }

    private var modelName: String {
        store.models.first(where: { $0.id == store.selectedModel })?.name ?? store.selectedModel
    }
}

struct SessionListView: View {
    @ObservedObject var store: NativeChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var renameItem: NativeSession?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.sessions) { session in
                    Button {
                        store.openSession(session.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: session.id == store.currentSessionID ? "circle.inset.filled" : "circle")
                                .foregroundStyle(session.id == store.currentSessionID ? OCTheme.accent : OCTheme.muted)
                                .font(.system(size: 13))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(OCTheme.text)
                                    .lineLimit(1)
                                Text(dateText(session.updated))
                                    .font(.system(size: 11))
                                    .foregroundStyle(OCTheme.muted)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.deleteSession(session.id)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        Button {
                            renameItem = session
                            renameText = session.title
                        } label: {
                            Label("Имя", systemImage: "pencil")
                        }
                        .tint(OCTheme.blue)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OCTheme.bg)
            .navigationTitle("Сессии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.newSession()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Переименовать", isPresented: Binding(
                get: { renameItem != nil },
                set: { if !$0 { renameItem = nil } }
            )) {
                TextField("Название", text: $renameText)
                Button("Отмена", role: .cancel) { renameItem = nil }
                Button("Сохранить") {
                    if let item = renameItem {
                        store.renameSession(item.id, title: renameText)
                    }
                    renameItem = nil
                }
            }
        }
        .tint(OCTheme.accent)
    }

    private func dateText(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

struct ModelPickerView: View {
    @ObservedObject var store: NativeChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Загружаем модели…").foregroundStyle(OCTheme.muted)
                    }
                } else {
                    let free = store.models.filter(\.free)
                    let paid = store.models.filter { !$0.free }
                    if !free.isEmpty {
                        Section("Бесплатные") {
                            ForEach(free, id: \.id) { model in row(model) }
                        }
                    }
                    if !paid.isEmpty {
                        Section("Платные / по ключу") {
                            ForEach(paid, id: \.id) { model in row(model) }
                        }
                    }
                    Section {
                        Text("Бесплатные модели Console работают только в официальном OpenCode. В этом приложении выбирай платную модель или модель Go.")
                            .font(.system(size: 12))
                            .foregroundStyle(OCTheme.muted)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(OCTheme.bg)
            .navigationTitle("Модель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await ZenClient.shared.refreshCatalog()
                            await MainActor.run { store.models = ZenClient.shared.selectableModels }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .tint(OCTheme.accent)
    }

    private func row(_ model: ZenModel) -> some View {
        Button {
            store.setModel(model.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(OCTheme.text)
                    Text("\(model.id) · \(contextText(model.context))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(OCTheme.muted)
                        .lineLimit(1)
                }
                Spacer()
                if model.free {
                    Text("free")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OCTheme.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(OCTheme.green.opacity(0.12), in: Capsule())
                }
                if store.selectedModel == model.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(OCTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func contextText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return "\(value / 1000)k" }
        return "\(value)"
    }
}

extension NativeChatStore {
    var currentTitle: String {
        sessions.first(where: { $0.id == currentSessionID })?.title ?? "OpenCode"
    }
}