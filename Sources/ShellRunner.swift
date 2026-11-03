import Foundation

/// Serializes ios_system calls. ios_system keeps one current session, so agent tools
/// and the visible terminal must never run a command at the same time.
///
/// ios_system itself only understands one command (plus its own pipe/redirection
/// parser). `&&`, `||` and `;` must be interpreted here; passing them through made
/// ios_system treat them as arguments and was the source of the shell crashes.
final class ShellRunner {
    static let shared = ShellRunner()

    private let queue = DispatchQueue(label: "app.opencodemob.shell")
    private var initialized = false
    private let lock = NSLock()
    private var directory = ""
    private let directoryLock = NSLock()

    private init() {}

    private func ensureInit() {
        lock.lock(); defer { lock.unlock() }
        if initialized { return }
        AgentPaths.prepare()
        OCMShellInit(AgentPaths.workspace.path)
        SetDirectory(AgentPaths.workspace.path)
        initialized = true
    }

    var lastWorkingDirectory: String {
        directoryLock.lock(); defer { directoryLock.unlock() }
        return directory
    }

    private func SetDirectory(_ path: String) {
        directoryLock.lock(); directory = path; directoryLock.unlock()
    }

    func run(_ command: String, cwd: String? = nil, timeout: TimeInterval = 90) -> (code: Int32, output: String) {
        ensureInit()
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        var output = ""
        queue.async {
            let result = self.executeScript(command,
                                           cwd: cwd ?? AgentPaths.workspace.path,
                                           timeout: timeout)
            code = result.code
            output = result.output
            self.SetDirectory(result.cwd)
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            OCMShellKill()
            _ = sem.wait(timeout: .now() + 5)
            return (124, output + "\n[команда остановлена по таймауту]")
        }
        return (code, output)
    }

    func runAsync(_ command: String, cwd: String?, timeout: TimeInterval = 90,
                  completion: @escaping (Int32, String) -> Void) {
        ensureInit()
        queue.async {
            let result = self.executeScript(command,
                                           cwd: cwd ?? AgentPaths.workspace.path,
                                           timeout: timeout)
            self.SetDirectory(result.cwd)
            DispatchQueue.main.async { completion(result.code, result.output) }
        }
    }

    func hasCommand(_ command: String) -> Bool {
        ensureInit()
        return OCMShellHasCommand(command)
    }

    func kill() {
        OCMShellKill()
    }

    // MARK: - script interpretation

    private struct ScriptResult {
        var code: Int32
        var output: String
        var cwd: String
    }

    /// Split at top-level `&&`, `||`, `;` and newlines. Quotes and escapes are
    /// preserved for the command implementations; a single `|`, `&`, `>` or `<`
    /// stays inside its command and is handled by ios_system.
    private func splitScript(_ script: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil
        let chars = Array(script)
        var index = 0

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { tokens.append(trimmed) }
            current.removeAll()
        }

        while index < chars.count {
            let c = chars[index]
            if let active = quote {
                current.append(c)
                if c == "\\", index + 1 < chars.count {
                    current.append(chars[index + 1])
                    index += 2
                    continue
                }
                if c == active { quote = nil }
                index += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
                current.append(c)
                index += 1
                continue
            }
            if c == "\\", index + 1 < chars.count {
                current.append(c)
                current.append(chars[index + 1])
                index += 2
                continue
            }
            if c == "&", index + 1 < chars.count, chars[index + 1] == "&" {
                flush()
                tokens.append("&&")
                index += 2
                continue
            }
            if c == "|", index + 1 < chars.count, chars[index + 1] == "|" {
                flush()
                tokens.append("||")
                index += 2
                continue
            }
            if c == ";" || c == "\n" {
                flush()
                index += 1
                continue
            }
            current.append(c)
            index += 1
        }
        flush()
        return tokens
    }

    private func words(_ command: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        let chars = Array(command)
        var index = 0
        func flush() {
            if !current.isEmpty { result.append(current) }
            current.removeAll()
        }
        while index < chars.count {
            let c = chars[index]
            if let active = quote {
                if c == active {
                    quote = nil
                } else if c == "\\", active == "\"", index + 1 < chars.count {
                    current.append(chars[index + 1])
                    index += 1
                } else {
                    current.append(c)
                }
                index += 1
                continue
            }
            if c == "'" || c == "\"" {
                quote = c
            } else if c == "\\", index + 1 < chars.count {
                current.append(chars[index + 1])
                index += 1
            } else if c == " " || c == "\t" {
                flush()
            } else {
                current.append(c)
            }
            index += 1
        }
        flush()
        return result
    }

    private func executeScript(_ script: String, cwd initialCwd: String, timeout: TimeInterval) -> ScriptResult {
        let tokens = splitScript(script)
        var cwd = initialCwd
        var lastCode: Int32 = 0
        var output = ""
        var runNext = true

        for token in tokens {
            if token == "&&" {
                runNext = lastCode == 0
                continue
            }
            if token == "||" {
                runNext = lastCode != 0
                continue
            }
            if token == ";" {
                runNext = true
                continue
            }
            guard runNext else { continue }
            let result = executeCommand(token, cwd: cwd, timeout: timeout)
            cwd = result.cwd
            lastCode = result.code
            if !result.output.isEmpty {
                output += result.output
                if !output.hasSuffix("\n") { output += "\n" }
            }
        }
        return ScriptResult(code: lastCode, output: output, cwd: cwd)
    }

    private func executeCommand(_ command: String, cwd: String, timeout: TimeInterval) -> (code: Int32, output: String, cwd: String) {
        var cwd = cwd
        let parts = words(command)

        if parts.first == "cd" {
            let target: String
            if parts.count < 2 || parts[1].isEmpty {
                target = AgentPaths.workspace.path
            } else if parts[1] == "~" {
                target = AgentPaths.workspace.path
            } else if parts[1].hasPrefix("~/") {
                target = AgentPaths.workspace.path + "/" + String(parts[1].dropFirst(2))
            } else {
                target = parts[1]
            }
            let candidate = target.hasPrefix("/") ? target : cwd + "/" + target
            guard let url = AgentPaths.resolve(candidate) else {
                return (1, "cd: outside workspace\n", cwd)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return (1, "cd: no such directory\n", cwd)
            }
            cwd = url.path
            return (0, "", cwd)
        }

        if parts.first == "pwd" {
            return (0, cwd + "\n", cwd)
        }

        if OCMPythonIsCommand(command) {
            let text = OCMPythonRun(command, cwd) ?? ""
            return (Int32(OCMPythonLastExit()), text, cwd)
        }
        if OCMGitIsCommand(command) {
            let text = OCMGitRun(command, cwd) ?? ""
            return (Int32(OCMGitLastExit()), text, cwd)
        }

        // Do not hand a completely unknown first word to ios_system. It has a
        // large command table, but malformed invocations can abort inside the
        // native loader; a normal shell should report 127 instead.
        if let first = parts.first, !first.contains("/"), !first.contains("="),
           !OCMShellHasCommand(first),
           !["echo", "printf", "export", "unset", "set", "true", "false", "help", "test", "[",
             "alias", "unalias", "history", "type", "command", "which", "source", ".",
             "sh", "dash", "bash", "umask", "jobs", "bg", "fg", "wait"].contains(first) {
            return (127, "shell: \(first): command not found\n", cwd)
        }

        var code: Int32 = 0
        let text = OCMRunCommand(command, cwd, &code) ?? ""
        return (code, text, cwd)
    }
}