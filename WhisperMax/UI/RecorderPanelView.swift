import SwiftUI

private enum RecorderTheme {
    static let accent = Color(red: 0.29, green: 0.56, blue: 0.98)
    static let accentGlow = Color(red: 0.36, green: 0.64, blue: 1.0)
    static let shellTop = Color(red: 0.038, green: 0.039, blue: 0.045)
    static let shellBottom = Color(red: 0.025, green: 0.026, blue: 0.031)
    static let waveTop = Color(red: 0.043, green: 0.044, blue: 0.05)
    static let waveBottom = Color(red: 0.02, green: 0.021, blue: 0.025)
    static let railTop = Color(red: 0.05, green: 0.051, blue: 0.058)
    static let railBottom = Color(red: 0.034, green: 0.035, blue: 0.04)
    static let shellStroke = Color.white.opacity(0.10)
    static let softStroke = Color.white.opacity(0.055)
    static let mutedText = Color.white.opacity(0.5)
}

struct RecorderPanelView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        GeometryReader { proxy in
            let outerHorizontalPadding: CGFloat = 12
            let outerVerticalPadding: CGFloat = 12
            let cornerRadius = min(max(proxy.size.height * 0.15, 22), 28)
            let contentHeight = proxy.size.height - (outerVerticalPadding * 2)
            let waveHeight = max(104, contentHeight * 0.58)

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [RecorderTheme.shellTop, RecorderTheme.shellBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(RecorderTheme.shellStroke, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.14), .clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )

                VStack(spacing: 0) {
                    RecorderWaveStage(levels: controller.waveformLevels)
                        .frame(height: waveHeight)

                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 1)

                    RecorderControlRail(
                        phase: controller.phase,
                        duration: controller.formattedDuration,
                        hotkeyText: controller.hotkeyDisplay,
                        statusText: controller.statusText,
                        stop: controller.stopRecording,
                        cancel: controller.cancelRecording
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .padding(.horizontal, outerHorizontalPadding)
            .padding(.vertical, outerVerticalPadding)
        }
    }
}

private struct RecorderWaveStage: View {
    let levels: [CGFloat]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [RecorderTheme.waveTop, RecorderTheme.waveBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(0.06),
                    .clear,
                ],
                center: .center,
                startRadius: 8,
                endRadius: 280
            )
            .blendMode(.screen)

            WaveformBarsView(levels: levels)
                .padding(.horizontal, 58)
                .padding(.top, 16)
                .padding(.bottom, 12)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.13))
                .padding(.top, 15)
                .padding(.trailing, 18)
        }
    }
}

private struct RecorderControlRail: View {
    let phase: RecordingPhase
    let duration: String
    let hotkeyText: String
    let statusText: String
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RecorderStatusDot(color: statusDotColor)

            leadPill

            Spacer(minLength: 18)

            trailingContent
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            LinearGradient(
                colors: [RecorderTheme.railTop, RecorderTheme.railBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var leadPill: some View {
        switch phase {
        case .recording, .ready:
            RecorderInfoPill(duration: duration, hotkeyText: hotkeyText)
        case .transcribing:
            RecorderPhasePill(
                title: "Transcribing",
                subtitle: "Local Whisper",
                accent: Color(red: 0.91, green: 0.73, blue: 0.28)
            )
        case .inserted(let method):
            RecorderPhasePill(
                title: method == .accessibility ? "Inserted" : "Pasted",
                subtitle: method == .accessibility ? "Directly into app" : "Clipboard fallback",
                accent: Color(red: 0.30, green: 0.78, blue: 0.52)
            )
        case .error:
            RecorderPhasePill(
                title: "Try Again",
                subtitle: "Recorder reset",
                accent: Color(red: 0.93, green: 0.38, blue: 0.34)
            )
        case .loadingModel:
            RecorderPhasePill(
                title: "Loading Model",
                subtitle: "Preparing local engine",
                accent: RecorderTheme.accent
            )
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch phase {
        case .recording:
            RecorderActionStrip(stop: stop, cancel: cancel)
        case .transcribing:
            RecorderStatusLabel(text: "Processing")
        case .inserted(let method):
            RecorderStatusLabel(text: method == .accessibility ? "Inserted" : "Pasted")
        case .error:
            RecorderStatusLabel(text: "Ready for another take")
        default:
            RecorderStatusLabel(text: statusText)
        }
    }

    private var statusDotColor: Color {
        switch phase {
        case .recording:
            RecorderTheme.accent
        case .transcribing:
            Color(red: 0.91, green: 0.73, blue: 0.28)
        case .inserted:
            Color(red: 0.30, green: 0.78, blue: 0.52)
        case .error:
            Color(red: 0.93, green: 0.38, blue: 0.34)
        default:
            Color.white.opacity(0.24)
        }
    }
}

private struct RecorderStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.45), radius: 8)
    }
}

private struct RecorderInfoPill: View {
    let duration: String
    let hotkeyText: String

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Text("Time ")
                    .foregroundStyle(.white.opacity(0.78))

                Text(duration)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.96))
            }
            .font(.system(size: 15, weight: .semibold))

            RecorderKeyBadge(text: hotkeyText, highlighted: true)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.065))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RecorderTheme.softStroke, lineWidth: 1)
                )
        )
    }
}

private struct RecorderPhasePill: View {
    let title: String
    let subtitle: String
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(accent)
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RecorderTheme.mutedText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(RecorderTheme.softStroke, lineWidth: 1)
                )
        )
    }
}

private struct RecorderActionStrip: View {
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button("Stop", action: stop)
                .buttonStyle(RecorderRailButtonStyle(weight: .semibold, color: .white.opacity(0.88)))

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(width: 1, height: 20)

            Button("Cancel", action: cancel)
                .buttonStyle(RecorderRailButtonStyle(weight: .medium, color: .white.opacity(0.5)))

            RecorderKeyBadge(text: "Esc", highlighted: false)
        }
    }
}

private struct RecorderStatusLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.64))
            .lineLimit(1)
    }
}

private struct RecorderRailButtonStyle: ButtonStyle {
    let weight: Font.Weight
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: weight))
            .foregroundStyle(color)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct RecorderKeyBadge: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(highlighted ? 0.90 : 0.74))
            .padding(.horizontal, highlighted ? 14 : 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: highlighted
                                ? [Color.black.opacity(0.34), RecorderTheme.accent.opacity(0.12)]
                                : [Color.black.opacity(0.28), Color.black.opacity(0.16)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                highlighted
                                    ? RecorderTheme.accentGlow.opacity(0.18)
                                    : Color.white.opacity(0.05),
                                lineWidth: 1
                            )
                    )
            )
    }
}
