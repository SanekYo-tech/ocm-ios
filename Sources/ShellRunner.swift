import Foundation

/// Serializes ios_system calls. ios_system keeps one current session, so agent tools
/// and the visible terminal must never run a command at the same time.
final class ShellRunner {
    static let shared = ShellRunner()

    private let queue = DispatchQueue(label: "app.opencodemob.shell")
    private var initialized = false
    private let lock = NSLock()

    private init() {}

    private func ensureInit() {
        lock.lock(); defer { lock.unlock() }
        if initialized { return }
        AgentPaths.prepare()
        OCMShellInit(AgentPaths.workspace.path)
        initialized = true
    }

    func run(_ command: String, cwd: String? = nil, timeout: TimeInterval = 90) -> (code: Int32, output: String) {
        ensureInit()
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        var output = ""
        queue.async {
            if OCMPythonIsCommand(command) {
                let text = OCMPythonRun(command, cwd ?? AgentPaths.workspace.path) ?? ""
                code = Int32(OCMPythonLastExit())
                output = text
                sem.signal()
                return
            }
            if OCMGitIsCommand(command) {
                let text = OCMGitRun(command, cwd ?? AgentPaths.workspace.path) ?? ""
                code = Int32(OCMGitLastExit())
                output = text
                sem.signal()
                return
            }
            var c: Int32 = 0
            let text = OCMRunCommand(command, cwd ?? AgentPaths.workspace.path, &c) ?? ""
            code = c
            output = text
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
            if OCMPythonIsCommand(command) {
                let text = OCMPythonRun(command, cwd ?? AgentPaths.workspace.path) ?? ""
                let code = Int32(OCMPythonLastExit())
                DispatchQueue.main.async { completion(code, text) }
                return
            }
            if OCMGitIsCommand(command) {
                let text = OCMGitRun(command, cwd ?? AgentPaths.workspace.path) ?? ""
                let code = Int32(OCMGitLastExit())
                DispatchQueue.main.async { completion(code, text) }
                return
            }
            var c: Int32 = 0
            let text = OCMRunCommand(command, cwd ?? AgentPaths.workspace.path, &c) ?? ""
            DispatchQueue.main.async { completion(c, text) }
        }
    }

    func hasCommand(_ command: String) -> Bool {
        ensureInit()
        return OCMShellHasCommand(command)
    }

    func kill() {
        OCMShellKill()
    }
}