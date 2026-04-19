import SwiftUI

private enum RecorderTheme {
    static let statusRecording = Color(red: 0.32, green: 0.82, blue: 0.56)
    static let statusInserted = Color(red: 0.33, green: 0.54, blue: 0.90)
    static let shellTop = Color(red: 0.038, green: 0.039, blue: 0.045)
    static let shellBottom = Color(red: 0.025, green: 0.026, blue: 0.031)
    static let waveTop = Color(red: 0.043, green: 0.044, blue: 0.05)
    static let waveBottom = Color(red: 0.02, green: 0.021, blue: 0.025)
    static let railTop = Color(red: 0.05, green: 0.051, blue: 0.058)
    static let railBottom = Color(red: 0.034, green: 0.035, blue: 0.04)
    static let shellStroke = Color.white.opacity(0.10)
    static let softStroke = Color.white.opacity(0.055)
    static let mutedText = Color.white.opacity(0.46)
}

struct RecorderPanelView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        GeometryReader { proxy in
            let outerHorizontalPadding: CGFloat = 8
            let outerVerticalPadding: CGFloat = 8
            let cornerRadius = min(max(proxy.size.height * 0.18, 18), 22)
            let contentHeight = proxy.size.height - (outerVerticalPadding * 2)
            let railHeight: CGFloat = 44
            let waveHeight = max(48, contentHeight - railHeight - 1)

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
                    RecorderWaveStage(
                        levels: controller.waveformLevels,
                        isRecording: controller.phase == .recording,
                        isTranscribing: controller.phase == .transcribing,
                        isInserted: controller.phase.isInsertedPhase,
                        isError: controller.phase.isErrorPhase,
                        transcribingStartTime: controller.transcribingAnimationStartTime
                    )
                        .frame(height: waveHeight)

                    Rectangle()
                        .fill(Color.white.opacity(0.09))
                        .frame(height: 1)

                    RecorderControlRail(
                        phase: controller.phase,
                        duration: controller.formattedDuration,
                        hotkeyText: controller.hotkeyDisplay,
                        height: railHeight,
                        openMicrophoneSettings: controller.openMicrophoneSettings,
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
    let isRecording: Bool
    let isTranscribing: Bool
    let isInserted: Bool
    let isError: Bool
    let transcribingStartTime: TimeInterval?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [RecorderTheme.waveTop, RecorderTheme.waveBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [Color.white.opacity(0.06), .clear],
                center: .center,
                startRadius: 8,
                endRadius: 280
            )
            .blendMode(.screen)

            WaveformBarsView(
                levels: levels,
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                isInserted: isInserted,
                isError: isError,
                transcribingStartTime: transcribingStartTime
            )
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

private struct RecorderControlRail: View {
    let phase: RecordingPhase
    let duration: String
    let hotkeyText: String
    let height: CGFloat
    let openMicrophoneSettings: () -> Void
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [RecorderTheme.railTop, RecorderTheme.railBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 12) {
                RecorderStatusDot(color: statusDotColor, pulseStyle: pulseStyle)

                leadContent

                Spacer(minLength: 18)

                trailingContent
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: height)
    }

    @ViewBuilder
    private var leadContent: some View {
        switch phase {
        case .recording, .ready:
            Text(duration)
                .monospacedDigit()
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
        case .transcribing:
            RecorderStateLabel(title: "Transcribing")
        case .inserted(let method):
            RecorderStateLabel(title: insertedTitle(for: method))
        case .error(let issue):
            RecorderStateLabel(title: issue.title, subtitle: issue.subtitle)
        case .loadingModel:
            RecorderStateLabel(title: "Loading model", subtitle: "Preparing local engine")
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch phase {
        case .recording:
            RecorderActionStrip(hotkeyText: hotkeyText, stop: stop, cancel: cancel)
        case .error(.microphonePermissionRequired):
            RecorderRecoveryStrip(title: "Grant Access", action: openMicrophoneSettings)
        default:
            EmptyView()
        }
    }

    private var statusDotColor: Color {
        switch phase {
        case .recording: RecorderTheme.statusRecording
        case .transcribing: Color(red: 0.42, green: 0.76, blue: 0.95)
        case .inserted: RecorderTheme.statusInserted
        case .error: Color(red: 0.93, green: 0.38, blue: 0.34)
        default: Color.white.opacity(0.24)
        }
    }

    private var pulseStyle: RecorderStatusDot.PulseStyle? {
        switch phase {
        case .recording: .recording
        case .transcribing: .transcribing
        default: nil
        }
    }

    private func insertedTitle(for method: InsertionMethod) -> String {
        switch method {
        case .accessibility:
            return "Inserted"
        case .clipboard:
            return "Pasted"
        case .copied:
            return "Copied to Clipboard"
        }
    }
}

private struct RecorderStatusDot: View {
    enum PulseStyle {
        case recording
        case transcribing

        var period: Double {
            switch self {
            case .recording: 1.3
            case .transcribing: 1.9
            }
        }

        var scaleAmplitude: CGFloat {
            switch self {
            case .recording: 0.11
            case .transcribing: 0.07
            }
        }

        var shadowRadius: (low: CGFloat, high: CGFloat) {
            switch self {
            case .recording: (4, 14)
            case .transcribing: (3, 9)
            }
        }

        var shadowOpacity: (low: Double, high: Double) {
            switch self {
            case .recording: (0.32, 0.82)
            case .transcribing: (0.26, 0.58)
            }
        }
    }

    let color: Color
    let pulseStyle: PulseStyle?

    var body: some View {
        if let pulseStyle {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * (2 * .pi / pulseStyle.period)) + 1) / 2
                let scale = 1.0 + pulseStyle.scaleAmplitude * CGFloat(phase)
                let shadowRadius = lerp(pulseStyle.shadowRadius.low, pulseStyle.shadowRadius.high, CGFloat(phase))
                let shadowOpacity = lerp(pulseStyle.shadowOpacity.low, pulseStyle.shadowOpacity.high, phase)

                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(shadowOpacity), radius: shadowRadius)
                    .scaleEffect(scale)
            }
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.30), radius: 4)
        }
    }

    private func lerp<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ t: T) -> T {
        a + (b - a) * t
    }
}

private struct RecorderStateLabel: View {
    let title: String
    let subtitle: String?

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RecorderTheme.mutedText)
            }
        }
    }
}

private struct RecorderActionStrip: View {
    let hotkeyText: String
    let stop: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Button("Stop", action: stop)
                    .buttonStyle(RecorderRailButtonStyle(weight: .semibold, color: .white.opacity(0.88)))

                RecorderKeyBadge(text: hotkeyText)
            }

            Rectangle()
                .fill(Color.white.opacity(0.11))
                .frame(width: 1, height: 20)

            Button(action: cancel) {
                HStack(spacing: 8) {
                    Text("Cancel")
                    RecorderKeyBadge(text: "Esc")
                }
            }
            .buttonStyle(RecorderRailButtonStyle(weight: .medium, color: .white.opacity(0.50)))
        }
        .frame(height: 38)
    }
}

private struct RecorderRecoveryStrip: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(RecorderRecoveryButtonStyle())
            .frame(height: 38)
    }
}

private struct RecorderRecoveryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(configuration.isPressed ? 0.13 : 0.10),
                                Color.white.opacity(configuration.isPressed ? 0.07 : 0.045),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(configuration.isPressed ? 0.16 : 0.12), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.34), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
            )
    }
}
