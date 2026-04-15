import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("whispermax")
                    .font(.system(size: 14, weight: .semibold))
                Text(controller.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open App") {
                controller.sidebarSelection = .home
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Open History") {
                controller.sidebarSelection = .history
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Label("Hotkey: \(controller.hotkeyDisplay)", systemImage: "keyboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Label("Model: \(controller.modelDisplayName)", systemImage: "cpu")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if !controller.accessibilityGranted {
                Button("Prompt Accessibility Access") {
                    controller.promptForAccessibility()
                }
            }

            Divider()

            Button("Quit whispermax") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
