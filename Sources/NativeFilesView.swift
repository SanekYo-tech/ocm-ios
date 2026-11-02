import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: String { url.path }
}

struct EditorTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct NativeFilesView: View {
    @State private var path: [URL] = []
    @State private var editorFile: EditorTarget?

    var body: some View {
        NavigationStack(path: $path) {
            FileBrowserView(directory: AgentPaths.workspace, onOpen: { editorFile = EditorTarget(url: $0) })
                .navigationDestination(for: URL.self) { dir in
                    FileBrowserView(directory: dir, onOpen: { editorFile = EditorTarget(url: $0) })
                }
                .navigationTitle("Файлы")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            path = []
                        } label: {
                            Image(systemName: "house")
                        }
                        .tint(OCTheme.accent)
                    }
                }
        }
        .tint(OCTheme.accent)
        .sheet(item: $editorFile) { target in
            FileEditorView(url: target.url)
        }
    }
}

struct FileBrowserView: View {
    let directory: URL
    let onOpen: (URL) -> Void

    @State private var items: [FileItem] = []
    @State private var refresh = 0
    @State private var showNew = false
    @State private var newName = ""
    @State private var newIsDirectory = false
    @State private var error: String?

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Пусто", systemImage: "folder")
                } description: {
                    Text("Здесь пока нет файлов")
                } actions: {
                    Button("Создать файл") {
                        newIsDirectory = false
                        newName = ""
                        showNew = true
                    }
                }
            } else {
                List {
                    ForEach(items) { item in
                        if item.isDirectory {
                            NavigationLink(value: item.url) {
                                row(item)
                            }
                        } else {
                            Button {
                                onOpen(item.url)
                            } label: {
                                row(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(OCTheme.bg)
        .navigationTitle(directory.lastPathComponent.isEmpty ? "OpenCode" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newIsDirectory = false
                        newName = ""
                        showNew = true
                    } label: {
                        Label("Новый файл", systemImage: "doc.badge.plus")
                    }
                    Button {
                        newIsDirectory = true
                        newName = ""
                        showNew = true
                    } label: {
                        Label("Новая папка", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .tint(OCTheme.accent)
            }
        }
        .alert("Новое имя", isPresented: $showNew) {
            TextField(newIsDirectory ? "Папка" : "файл.txt", text: $newName)
            Button("Отмена", role: .cancel) {}
            Button("Создать") { create() }
        } message: {
            Text(newIsDirectory ? "Название новой папки" : "Название нового файла")
        }
        .alert("Ошибка", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("Закрыть", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onAppear { load() }
        .onChange(of: refresh) { load() }
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.isDirectory ? "folder.fill" : icon(item.url))
                .font(.system(size: 16))
                .foregroundStyle(item.isDirectory ? OCTheme.accent : OCTheme.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 14))
                    .foregroundStyle(OCTheme.text)
                    .lineLimit(1)
                if !item.isDirectory {
                    Text(detail(item.url))
                        .font(.system(size: 10.5))
                        .foregroundStyle(OCTheme.muted)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private func icon(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "ts", "tsx", "jsx": return "curlybraces"
        case "json", "jsonc": return "curlybraces.square"
        case "md": return "text.document"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        case "zip", "gz", "tar": return "archivebox"
        default: return "doc.text"
        }
    }

    private func detail(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
        if let date = values?.contentModificationDate {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            return "\(size) · \(f.string(from: date))"
        }
        return size
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls.compactMap { url in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if url.lastPathComponent == ".opencode" || url.lastPathComponent == ".git" { return nil }
            return FileItem(url: url, isDirectory: isDir)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        let url = directory.appendingPathComponent(name)
        do {
            if newIsDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data())
            }
            refresh += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            do {
                try FileManager.default.removeItem(at: items[index].url)
            } catch {
                self.error = error.localizedDescription
            }
        }
        refresh += 1
    }
}

struct FileEditorView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var copied = false

    private var changed: Bool { text != original }

    var body: some View {
        NavigationStack {
            ZStack {
                OCTheme.bg.ignoresSafeArea()
                if loaded {
                    TextEditor(text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
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
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = text
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button("Сохранить") { save() }
                            .fontWeight(.semibold)
                            .disabled(!changed)
                    }
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
            .onAppear(perform: load)
        }
        .tint(OCTheme.accent)
    }

    private func load() {
        guard !loaded else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 2_000_000, let value = String(data: data, encoding: .utf8) else {
                error = "Файл слишком большой или бинарный"
                loaded = true
                return
            }
            text = value
            original = value
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            original = text
            if url.lastPathComponent == "config.json" {
                AgentEngine.shared.reloadConfig()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}