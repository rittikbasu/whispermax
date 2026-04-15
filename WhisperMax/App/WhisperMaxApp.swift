import SwiftUI

@main
struct WhisperMaxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("WhisperMax", id: "main") {
            MainWindowView()
                .environment(appDelegate.controller)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("WhisperMax", systemImage: "waveform.circle.fill") {
            MenuBarView()
                .environment(appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
