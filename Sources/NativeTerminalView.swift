import SwiftUI
import UIKit

struct NativeTerminalView: View {
    @State private var output = ""
    @State private var command = ""
    @State private var cwd = AgentPaths.workspace.path
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                OCTheme.bg.ignoresSafeArea()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(output.isEmpty ? welcome : output)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OCTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                        Color.clear.frame(height: 1).id("termBottom")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: output) {
                        proxy.scrollTo("termBottom", anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 7) {
                    Text(prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OCTheme.green)
                        .lineLimit(1)
                    TextField("команда", text: $command)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(OCTheme.text)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit(run)
                    Button {
                        if busy {
                            ShellRunner.shared.kill()
                        } else {
                            run()
                        }
                    } label: {
                        Image(systemName: busy ? "stop.fill" : "return")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                            .background(OCTheme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassSurface(cornerRadius: 18)
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
            }
            .navigationTitle("Терминал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            output = ""
                        } label: {
                            Label("Очистить", systemImage: "trash")
                        }
                        Button {
                            output += "\n$ " + command + "\n"
                            command = ""
                        } label: {
                            Label("Вставить приглашение", systemImage: "text.cursor")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .tint(OCTheme.text)
                }
            }
            .onAppear {
                if output.isEmpty { output = welcome }
            }
        }
        .tint(OCTheme.accent)
    }

    private var welcome: String {
        """
        OpenCode shell · ios_system
        Workspace: \(AgentPaths.workspace.path)
        git: init/status/add/commit/log/diff/branch/checkout
        python3: script.py или -c "…" (beta)
        help — список команд
        """
    }

    private var prompt: String {
        let rel = AgentPaths.relative(URL(fileURLWithPath: cwd))
        return "opencode:\(rel.isEmpty ? "/" : "/" + rel)$"
    }

    private func run() {
        let raw = command.trimmingCharacters(in: .whitespacesAndNewlines)
        command = ""
        guard !raw.isEmpty, !busy else { return }
        output += "\n\(prompt) \(raw)\n"
        if raw == "clear" { output = ""; return }
        if raw == "help" {
            output += """
            ls cat cd pwd echo grep sed awk find sort uniq wc diff cp mv rm mkdir touch chmod tar gzip
            git init/status/add/reset/commit -m/log/diff/branch/checkout/rev-parse/remote/config/clone
            python3 script.py | python3 -c "код" (beta)
            Нет node, npm, pip, ssl, sqlite3 и компиляторов.
            """
            return
        }
        if raw == "cd" {
            cwd = AgentPaths.workspace.path
            return
        }
        if raw.hasPrefix("cd ") {
            let target = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let candidate = target.hasPrefix("/") ? target : cwd + "/" + target
            if let url = AgentPaths.resolve(candidate) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    cwd = url.path
                } else {
                    output += "cd: no such directory\n"
                }
            } else {
                output += "cd: outside workspace\n"
            }
            return
        }
        busy = true
        let workdir = cwd
        Task.detached(priority: .userInitiated) {
            let result = ShellRunner.shared.run(raw, cwd: workdir, timeout: 120)
            await MainActor.run {
                busy = false
                if !result.output.isEmpty {
                    output += result.output
                    if !result.output.hasSuffix("\n") { output += "\n" }
                }
                if result.code != 0 {
                    output += "[код \(result.code)]\n"
                }
                output += prompt + " "
            }
        }
    }
}