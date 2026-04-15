import SwiftUI

@main
struct WhisperMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("whispermax", id: "main") {
            MainWindowView()
                .frame(minWidth: 1040, minHeight: 760)
                .environment(appDelegate.controller)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 840)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("whispermax", image: "WhisperMaxMenuBarMark") {
            MenuBarView()
                .environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
