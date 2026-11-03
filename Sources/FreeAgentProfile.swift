import Foundation

/// Console grants the free model quota only to requests that carry the
/// official OpenCode system prompt and tool schemas. Keep this profile
/// separate from the normal iOS agent prompts; paid models don't need it.
struct FreeAgentProfile {
    static let shared = FreeAgentProfile()

    private let rawSystem: String
    private let allTools: [[String: Any]]

    private init() {
        guard let url = Bundle.main.url(forResource: "free-agent", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let system = obj["system"] as? String,
              let tools = obj["tools"] as? [[String: Any]] else {
            rawSystem = ""
            allTools = []
            return
        }
        rawSystem = system
        allTools = tools
    }

    var available: Bool { !rawSystem.isEmpty && !allTools.isEmpty }

    func system(model: String) -> String {
        guard available else { return "" }
        let path = AgentPaths.workspace.path
        var text = rawSystem
        text = replaceLine(in: text, prefix: "Working directory: ", value: path)
        text = replaceLine(in: text, prefix: "Workspace root folder: ", value: path)
        text = replaceLine(in: text, prefix: "Is directory a git repo: ", value: "no")
        text = replaceLine(in: text, prefix: "Platform: ", value: "ios")
        text = replaceLine(in: text, prefix: "Today's date: ", value: Self.dateText())
        text = text.replacingOccurrences(of: "big-pickle", with: model)
        return text
    }

    func tools(readOnly: Bool) -> [[String: Any]] {
        guard available else { return [] }
        if !readOnly { return allTools }
        let allowed: Set<String> = ["read", "glob", "grep"]
        return allTools.filter { item in
            guard let fn = item["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return false }
            return allowed.contains(name)
        }
    }

    private func replaceLine(in text: String, prefix: String, value: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let mapped = lines.map { line -> String in
            let leading = String(line.prefix { $0 == " " || $0 == "\t" })
            let content = String(line.dropFirst(leading.count))
            return content.hasPrefix(prefix) ? leading + prefix + value : line
        }
        return mapped.joined(separator: "\n")
    }

    private static func dateText() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd yyyy"
        return formatter.string(from: Date())
    }
}