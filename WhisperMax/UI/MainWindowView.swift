import SwiftUI

private enum Theme {
    static let accent = Color(red: 0.34, green: 0.57, blue: 0.97)
    static let accentMuted = Color(red: 0.16, green: 0.24, blue: 0.40)
    static let shell = Color(red: 0.03, green: 0.03, blue: 0.038)
    static let shellEdge = Color.white.opacity(0.07)
    static let panel = Color.white.opacity(0.022)
}

struct MainWindowView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        ZStack {
            Theme.shell
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarRail()

                Divider()
                    .overlay(Color.white.opacity(0.05))

                MainContentArea()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.shell)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.shellEdge, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .ignoresSafeArea()
        }
        .background(WindowChromeConfigurator())
    }
}

private struct SidebarRail: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                AppGlyph()
                    .padding(.top, 56)
                    .padding(.bottom, 16)

                SidebarButton(
                    systemName: "house",
                    isSelected: controller.sidebarSelection == .home,
                    action: selectHome
                )

                SidebarButton(
                    systemName: "clock.arrow.circlepath",
                    isSelected: controller.sidebarSelection == .history,
                    action: selectHistory
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
                .overlay(Color.white.opacity(0.05))

            SidebarButton(
                systemName: "gearshape",
                isSelected: controller.sidebarSelection == .settings,
                action: selectSettings
            )
            .padding(.vertical, 18)
        }
        .frame(width: 80)
        .background(Color.black.opacity(0.26))
    }

    private func selectHome() {
        controller.sidebarSelection = .home
    }

    private func selectHistory() {
        controller.sidebarSelection = .history
    }

    private func selectSettings() {
        controller.sidebarSelection = .settings
    }
}

private struct AppGlyph: View {
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                GlyphDot(opacity: 0.42)
                GlyphDot(opacity: 0.84)
            }

            HStack(spacing: 4) {
                GlyphDot(opacity: 0.84)
                GlyphDot(opacity: 0.42)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct GlyphDot: View {
    let opacity: Double

    var body: some View {
        Circle()
            .fill(Theme.accent.opacity(opacity))
            .frame(width: 4, height: 4)
    }
}

private struct SidebarButton: View {
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isSelected ? Theme.accentMuted.opacity(0.76) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(isSelected ? Theme.accent.opacity(0.18) : .clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct MainContentArea: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                WindowHeader()

                if controller.needsSetup {
                    PermissionSetupPanel()
                }

                switch controller.sidebarSelection {
                case .home, .history:
                    HistorySection()
                case .settings:
                    SettingsSection()
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 58)
            .padding(.bottom, 26)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.043, green: 0.043, blue: 0.054),
                    Color(red: 0.024, green: 0.024, blue: 0.031),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct WindowHeader: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(greetingTitle)
                    .font(.system(size: 39, weight: .semibold))
                    .tracking(-1.0)
                    .foregroundStyle(.white)

                Text(controller.homeSubtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 20)

            SearchField(text: Bindable(controller).searchText)
                .frame(width: 174)
                .padding(.top, 8)
        }
    }

    private var greetingTitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:
            return "Good morning"
        case 12..<17:
            return "Good afternoon"
        default:
            return "Good evening"
        }
    }
}

private struct PermissionSetupPanel: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SETUP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(Theme.accent)

                Text("Finish permissions for automatic dictation.")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Microphone lets WhisperMax record. Accessibility lets it insert text into other apps.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Microphone",
                    subtitle: controller.microphoneGranted ? "Ready" : "Required to capture dictation audio",
                    isGranted: controller.microphoneGranted,
                    buttonTitle: "Open Microphone Settings",
                    action: controller.openMicrophoneSettings
                )

                PermissionRow(
                    title: "Accessibility",
                    subtitle: controller.accessibilityGranted ? "Ready" : "Required for direct insertion into other apps",
                    isGranted: controller.accessibilityGranted,
                    buttonTitle: "Open Accessibility Settings",
                    action: controller.openAccessibilitySettings
                )
            }

            HStack(spacing: 10) {
                if !controller.accessibilityGranted {
                    Button("Prompt Accessibility Again", action: controller.promptForAccessibility)
                        .buttonStyle(PanelButtonStyle(prominent: false))
                }

                Button("Refresh Permissions", action: controller.refreshPermissions)
                    .buttonStyle(PanelButtonStyle(prominent: false))

                Spacer()

                HotkeyBadge(text: controller.hotkeyDisplay)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(PanelCardBackground(cornerRadius: 20))
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(isGranted ? Theme.accent : Color(red: 0.91, green: 0.67, blue: 0.27))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.38))
            }

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
            } else {
                Button(buttonTitle, action: action)
                    .buttonStyle(PanelButtonStyle(prominent: true))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.024))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.045), lineWidth: 1)
                )
        )
    }
}

private struct HistorySection: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "RECENT TRANSCRIPTIONS")

            VStack(spacing: 0) {
                if controller.filteredHistory.isEmpty {
                    EmptyHistoryState()
                } else {
                    ForEach(controller.filteredHistory) { entry in
                        HistoryRow(entry: entry)

                        if entry.id != controller.filteredHistory.last?.id {
                            Divider()
                                .overlay(Color.white.opacity(0.04))
                        }
                    }
                }
            }
            .background(PanelCardBackground(cornerRadius: 22))

            HStack {
                Text("\(controller.history.count) TRANSCRIPTIONS")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.26))

                Spacer()

                Button("CLEAR ALL", action: controller.clearHistory)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .tracking(2.2)
            .foregroundStyle(.white.opacity(0.4))
    }
}

private struct EmptyHistoryState: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No transcripts yet")
                .font(.system(size: 28, weight: .medium))
                .tracking(-0.65)
                .foregroundStyle(.white.opacity(0.92))

            Text(emptyStateBody)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
    }

    private var emptyStateBody: String {
        if controller.needsSetup {
            return "Finish setup above, then press \(controller.hotkeyInstructionText) to start recording. Your recent insertions will appear here."
        }

        return "Press \(controller.hotkeyInstructionText), talk, and your recent insertions will appear here."
    }
}

private struct HistoryRow: View {
    @Environment(AppController.self) private var controller

    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)

                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened).uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.38))

                Spacer()
            }

            Text(entry.text)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Label("\(Int(entry.duration.rounded()))s audio", systemImage: "waveform")
                Label(entry.insertionMethod.rawValue, systemImage: "arrow.up.forward")
                Label(entry.modelName, systemImage: "cpu")

                Spacer()

                Button("Copy", action: copy)
                    .buttonStyle(.plain)

                Button("Insert", action: reinsert)
                    .buttonStyle(.plain)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.34))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func copy() {
        controller.copy(entry)
    }

    private func reinsert() {
        controller.reinsert(entry)
    }
}

private struct SettingsSection: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "SETTINGS")

            VStack(alignment: .leading, spacing: 16) {
                SettingRow(label: "Hotkey", value: controller.hotkeyDisplay)
                SettingRow(label: "Model", value: controller.modelDisplayName)
                SettingRow(label: "Model Path", value: controller.modelPath)
                SettingRow(label: "Accessibility", value: controller.accessibilityGranted ? "Granted" : "Not Granted")
                SettingRow(label: "Microphone", value: controller.microphoneGranted ? "Granted" : "Not Granted")

                HStack(spacing: 10) {
                    Button("Prompt Accessibility Again", action: controller.promptForAccessibility)
                        .buttonStyle(PanelButtonStyle(prominent: false))

                    Button("Open Microphone Settings", action: controller.openMicrophoneSettings)
                        .buttonStyle(PanelButtonStyle(prominent: false))

                    Button("Refresh Permissions", action: controller.refreshPermissions)
                        .buttonStyle(PanelButtonStyle(prominent: false))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .background(PanelCardBackground(cornerRadius: 20))
        }
    }
}

private struct SettingRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.34))

            Text(value)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))

            TextField("Search...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
    }
}

private struct HotkeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.accent.opacity(0.08))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Theme.accent.opacity(0.14), lineWidth: 1)
                    )
            )
    }
}

private struct PanelButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(prominent ? 0.88 : 0.72))
            .padding(.horizontal, prominent ? 14 : 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        prominent
                            ? Theme.accentMuted.opacity(configuration.isPressed ? 0.28 : 0.18)
                            : Color.white.opacity(configuration.isPressed ? 0.08 : 0.045)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                prominent ? Theme.accent.opacity(0.18) : Color.white.opacity(0.05),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct PanelCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.065), lineWidth: 1)
            )
    }
}
