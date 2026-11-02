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
        .task { chat.bootstrap() }

    }
}