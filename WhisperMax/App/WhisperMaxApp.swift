import SwiftUI

@main
struct WhisperMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("whispermax", id: "main") {
            MainWindowView()
                .environment(appDelegate.controller)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 840)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("whispermax", image: "WhisperMaxMenuBarMark", isInserted: Binding(
            get: { appDelegate.controller.hasCompletedOnboarding },
            set: { _ in }
        )) {
            MenuBarView()
                .environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
