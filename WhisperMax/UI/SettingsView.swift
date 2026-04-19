import AppKit
import SwiftUI

// MARK: - Theme

private enum SettingsTheme {
    static let cardFill = Color.white.opacity(0.022)
    static let cardBorder = Color.white.opacity(0.058)
    static let cardCornerRadius: CGFloat = 14

    static let rowFill = Color.white.opacity(0.024)
    static let rowBorder = Color.white.opacity(0.045)

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.42)
    static let eyebrow = Color.white.opacity(0.36)

    static let accentBlue = Color(red: 0.49, green: 0.68, blue: 0.98)
    static let accentFill = Color(red: 0.16, green: 0.21, blue: 0.31)
    static let accentStroke = Color(red: 0.36, green: 0.50, blue: 0.80).opacity(0.48)

    static let grantedGreen = Color(red: 0.30, green: 0.78, blue: 0.52)
    static let pendingAmber = Color(red: 0.91, green: 0.67, blue: 0.27)
}

// MARK: - Entry Point

struct SettingsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            TriggerSettingsCard()
            ModelSettingsCard()
            InputSettingsCard()
            PermissionsSettingsCard()
            AboutSettingsCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card Primitive

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(SettingsTheme.eyebrow)

            content()
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                        .fill(SettingsTheme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: SettingsTheme.cardCornerRadius, style: .continuous)
                                .stroke(SettingsTheme.cardBorder, lineWidth: 1)
                        )
                )
        }
    }
}

// MARK: - Trigger

private struct TriggerSettingsCard: View {
    @State private var isHovering = false

    var body: some View {
        SettingsCard(title: "TRIGGER") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hotkey")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primaryText)
                    Text("Press anywhere to start and stop dictation.")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(SettingsTheme.secondaryText)
                }

                Spacer(minLength: 16)

                KeycapGroup(isPressed: isHovering, scale: 0.78)
                    .onHover { isHovering = $0 }
                    .help("\u{2325} Space \u{2014} global dictation hotkey")
            }
        }
    }
}

// MARK: - Model

private struct ModelSettingsCard: View {
    @Environment(AppController.self) private var controller
    @State private var modelByteSize: Int64?

    var body: some View {
        SettingsCard(title: "MODEL") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.modelDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primaryText)

                    Text(secondaryLine)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(SettingsTheme.secondaryText)
                        .monospacedDigit()
                }

                Spacer(minLength: 16)

                if !controller.modelPath.isEmpty {
                    IconActionButton(
                        systemName: "folder",
                        help: "Show in Finder",
                        action: revealInFinder
                    )
                }
            }
        }
        .task(id: controller.modelPath) {
            modelByteSize = ModelFileInspector.byteSize(at: controller.modelPath)
        }
    }

    private var secondaryLine: String {
        var pieces: [String] = []
        if let modelByteSize {
            pieces.append(Self.byteFormatter.string(fromByteCount: modelByteSize))
        }
        if let filename = modelFilename {
            pieces.append(filename)
        }
        return pieces.joined(separator: "  \u{00B7}  ")
    }

    private var modelFilename: String? {
        guard !controller.modelPath.isEmpty else { return nil }
        let basename = (controller.modelPath as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }

    private func revealInFinder() {
        let url = URL(fileURLWithPath: controller.modelPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()
}

private enum ModelFileInspector {
    static func byteSize(at path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }
}

// MARK: - Input

private struct InputSettingsCard: View {
    @Environment(AppController.self) private var controller
    @State private var pickerPresented = false

    var body: some View {
        SettingsCard(title: "INPUT") {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Microphone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SettingsTheme.primaryText)
                    Text(activeDescription)
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(SettingsTheme.secondaryText)
                }

                Spacer(minLength: 16)

                InputPickerButton(
                    label: controller.inputMenuLabel,
                    isPresented: $pickerPresented,
                    needsAttention: controller.unavailablePinnedInput != nil
                )
                .popover(isPresented: $pickerPresented, arrowEdge: .top) {
                    InputPickerPopover(dismiss: { pickerPresented = false })
                }
            }
        }
        .onAppear {
            controller.refreshInputDevices()
        }
    }

    private var activeDescription: String {
        if let unavailable = controller.unavailablePinnedInput {
            return "\(unavailable.name) unavailable \u{2014} using \(controller.activeInputDisplayName)."
        }

        switch controller.inputPreference {
        case .systemDefault:
            return "Using the Mac's default mic."
        case .pinned:
            return "Pinned to this mic whenever it's connected."
        }
    }
}

private struct InputPickerButton: View {
    let label: String
    @Binding var isPresented: Bool
    let needsAttention: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                if needsAttention {
                    Circle()
                        .fill(SettingsTheme.pendingAmber)
                        .frame(width: 6, height: 6)
                }

                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.44))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct InputPickerPopover: View {
    @Environment(AppController.self) private var controller
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickerSectionLabel("DEFAULT")

            SystemDefaultPickerRow(dismiss: dismiss)

            if !controller.inputDevices.isEmpty {
                PickerDivider()
                PickerSectionLabel("PIN A DEVICE")

                ForEach(controller.inputDevices) { device in
                    DevicePickerRow(device: device, dismiss: dismiss)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .onAppear {
            controller.refreshInputDevices()
        }
    }
}

private struct PickerSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.32))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PickerDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 0.5)
            .padding(.vertical, 6)
    }
}

private struct SystemDefaultPickerRow: View {
    @Environment(AppController.self) private var controller
    let dismiss: () -> Void

    var body: some View {
        PickerRow(
            primary: "System Default",
            secondary: controller.defaultInputDeviceName == "No Input Device"
                ? nil
                : controller.defaultInputDeviceName,
            isSelected: controller.prefersSystemDefaultInput
        ) {
            controller.useSystemDefaultInput()
            dismiss()
        }
    }
}

private struct DevicePickerRow: View {
    @Environment(AppController.self) private var controller
    let device: AudioInputDevice
    let dismiss: () -> Void

    var body: some View {
        PickerRow(
            primary: device.name,
            secondary: nil,
            isSelected: controller.isPreferredInput(device)
        ) {
            controller.pinInputDevice(device)
            dismiss()
        }
    }
}

private struct PickerRow: View {
    let primary: String
    let secondary: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? SettingsTheme.accentBlue : .clear)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    Text(primary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)

                    if let secondary {
                        Text(secondary)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.40))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Permissions

private struct PermissionsSettingsCard: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        SettingsCard(title: "PERMISSIONS") {
            VStack(spacing: 10) {
                PermissionStatusRow(
                    title: "Microphone",
                    subtitleGranted: "Captures your voice locally.",
                    subtitlePending: "Needed to capture dictation audio.",
                    isGranted: controller.microphoneGranted,
                    buttonTitle: "Open Settings",
                    action: controller.openMicrophoneSettings
                )

                PermissionStatusRow(
                    title: "Accessibility",
                    subtitleGranted: "Inserts transcriptions into other apps.",
                    subtitlePending: "Needed to type into other apps.",
                    isGranted: controller.accessibilityGranted,
                    buttonTitle: "Grant Access",
                    action: controller.beginAccessibilityPermissionFlow
                )

                HStack {
                    Spacer()
                    RefreshLink(action: controller.refreshPermissions)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let subtitleGranted: String
    let subtitlePending: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(isGranted ? SettingsTheme.grantedGreen : SettingsTheme.pendingAmber)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(isGranted ? subtitleGranted : subtitlePending)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 12)

            if isGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SettingsTheme.grantedGreen)
                    Text("Granted")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }
            } else {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(SettingsTheme.accentFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(SettingsTheme.accentStroke, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SettingsTheme.rowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(SettingsTheme.rowBorder, lineWidth: 1)
                )
        )
    }
}

private struct RefreshLink: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                Text("Refresh permissions")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.60 : 0.36))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Re-check system permission status")
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - About

private struct AboutSettingsCard: View {
    @Environment(AppController.self) private var controller

    private static let releaseNotesURL = URL(string: "https://github.com/rittikbasu/whispermax/releases")!
    private static let repoURL = URL(string: "https://github.com/rittikbasu/whispermax")!

    var body: some View {
        SettingsCard(title: "ABOUT") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("whispermax \(controller.appVersionDisplay)")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SettingsTheme.primaryText)
                            .monospacedDigit()

                        Text(secondaryLine)
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(SettingsTheme.secondaryText)
                    }

                    Spacer(minLength: 16)

                    Button(controller.updateActionTitle) {
                        if controller.availableUpdate != nil {
                            controller.openAvailableUpdate()
                        } else {
                            controller.checkForUpdates()
                        }
                    }
                    .buttonStyle(SettingsPillButtonStyle(prominent: controller.availableUpdate != nil))
                    .disabled(controller.availableUpdate == nil && !controller.canCheckForUpdates)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.045))
                    .frame(height: 0.5)

                HStack(spacing: 18) {
                    ExternalLinkButton(title: "Release notes", url: Self.releaseNotesURL)
                    ExternalLinkButton(title: "GitHub", url: Self.repoURL)
                    Spacer()
                }
            }
        }
    }

    private var secondaryLine: String {
        if let update = controller.availableUpdate {
            return "Update \(update.version) is ready."
        }
        return "Checks for updates automatically."
    }
}

private struct ExternalLinkButton: View {
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.72 : 0.38))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

// MARK: - Shared Styles

private struct SettingsPillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(prominent ? 0.94 : 0.72))
            .padding(.horizontal, prominent ? 14 : 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor(pressed: configuration.isPressed))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(strokeColor, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private func fillColor(pressed: Bool) -> Color {
        if prominent {
            return SettingsTheme.accentFill.opacity(pressed ? 0.86 : 1)
        }
        return Color.white.opacity(pressed ? 0.10 : 0.06)
    }

    private var strokeColor: Color {
        prominent ? SettingsTheme.accentStroke : Color.white.opacity(0.08)
    }
}

private struct IconActionButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 0.88 : 0.62))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
