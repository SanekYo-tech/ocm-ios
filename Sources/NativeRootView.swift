import SwiftUI

struct RootView: View {
    @StateObject private var chat = NativeChatStore()

    var body: some View {
        ZStack {
            OCTheme.bg.ignoresSafeArea()

            TabView {
                NativeChatView()
                    .environmentObject(chat)
                    .tabItem { Label("Чат", systemImage: "bubble.left.and.bubble.right") }

                NativeFilesView()
                    .tabItem { Label("Файлы", systemImage: "folder") }

                NativeTerminalView()
                    .tabItem { Label("Терминал", systemImage: "terminal") }

                NativeSettingsView()
                    .environmentObject(chat)
                    .tabItem { Label("Настройки", systemImage: "slider.horizontal.3") }
            }
            .tint(OCTheme.accent)
        }
        .preferredColorScheme(.dark)
        .task {
            chat.bootstrap()
            if ProcessInfo.processInfo.environment["OCM_BORING_TEST"] == "1" {
                Task {
                    let model = "big-pickle"
                    let sid = newSessionID()
                    let profile = FreeAgentProfile.shared
                    let messages: [[String: Any]] = [
                        ["role": "system", "content": profile.system(model: model)],
                        ["role": "user", "content": "Reply with exactly OK"]
                    ]
                    do {
                        let result = try await ZenClient.shared.stream(model: model, sessionID: sid, messages: messages, tools: profile.tools(readOnly: false)) { _, _ in }
                        NSLog("OCM BORING OK [%@]", result.text)
                    } catch {
                        NSLog("OCM BORING ERR [%@]", String(describing: error))
                    }
                }
            }
        }

    }
}