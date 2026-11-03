import SwiftUI

@main
struct OpenCodeMobileApp: App {
    init() {
        BackgroundKeeper.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .ignoresSafeArea()
        }
    }
}