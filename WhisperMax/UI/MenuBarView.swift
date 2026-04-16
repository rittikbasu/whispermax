import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Button(controller.menuPrimaryActionTitle) {
                Task {
                    await controller.toggleRecording()
                }
            }
            .disabled(!controller.isMenuPrimaryActionEnabled)

            Button("Copy Last Transcript") {
                controller.copyLastTranscript()
            }
            .disabled(!controller.canCopyLastTranscript)

            if let menuFeedbackMessage = controller.menuFeedbackMessage {
                Divider()

                Text(menuFeedbackMessage)
            }

            Divider()

            Button("History") {
                controller.sidebarSelection = .history
                openMainWindow()
            }

            Button("Settings") {
                controller.sidebarSelection = .settings
                openMainWindow()
            }

            Menu {
                if controller.inputDevices.isEmpty {
                    Text("No input devices available")
                } else {
                    Button {
                        controller.useSystemDefaultInput()
                    } label: {
                        if controller.prefersSystemDefaultInput {
                            Label(systemDefaultMenuItemTitle, systemImage: "checkmark")
                        } else {
                            Text(systemDefaultMenuItemTitle)
                        }
                    }

                    if let unavailablePinnedInput = controller.unavailablePinnedInput {
                        Divider()
                        Text("\(unavailablePinnedInput.name) unavailable")
                    }

                    Divider()

                    ForEach(controller.inputDevices) { device in
                        Button {
                            controller.pinInputDevice(device)
                        } label: {
                            if controller.isPreferredInput(device) {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                }
            } label: {
                Text(controller.inputMenuLabel)
            }

            if !controller.accessibilityGranted {
                Divider()

                Button("Prompt Accessibility Access") {
                    controller.promptForAccessibility()
                }
            }

            Divider()

            Button("Quit whispermax") {
                NSApp.terminate(nil)
            }
        }
        .onAppear {
            controller.refreshInputDevices()
        }
    }

    private var systemDefaultMenuItemTitle: String {
        controller.defaultInputDeviceName == "No Input Device"
            ? "System Default"
            : "System Default (\(controller.defaultInputDeviceName))"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
