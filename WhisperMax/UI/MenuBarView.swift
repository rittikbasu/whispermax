import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if controller.hasCompletedOnboarding {
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

                Divider()

                if let menuFeedbackMessage = controller.menuFeedbackMessage {
                    Text(menuFeedbackMessage)

                    Divider()
                }

                Button("Transcriptions") {
                    controller.sidebarSelection = .home
                    openMainWindow()
                }

                Button("Dictionary") {
                    controller.sidebarSelection = .dictionary
                    openMainWindow()
                }

                Button("Settings") {
                    controller.sidebarSelection = .settings
                    openMainWindow()
                }

                Button("Check for Updates…") {
                    controller.checkForUpdates()
                }
                .disabled(!controller.canCheckForUpdates)

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
            } else {
                Button(onboardingPrimaryActionTitle) {
                    openMainWindow()
                }

                Divider()

                Button("Quit whispermax") {
                    NSApp.terminate(nil)
                }
            }
        }
        .onAppear {
            if controller.hasCompletedOnboarding {
                controller.refreshInputDevices()
            }
        }
    }

    private var onboardingPrimaryActionTitle: String {
        controller.onboardingMode == .modelRepair ? "Repair Model" : "Continue Setup"
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
