import SwiftUI

struct WaveformBarsView: View {
    let levels: [CGFloat]
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isInserted: Bool = false
    var isError: Bool = false
    var transcribingStartTime: TimeInterval? = nil

    private enum Mode: Equatable {
        case idle
        case recording
        case transcribing
        case inserted
        case error
    }

    private var mode: Mode {
        if isInserted { return .inserted }
        if isTranscribing { return .transcribing }
        if isError { return .error }
        if isRecording { return .recording }
        return .idle
    }

    var body: some View {
        ZStack {
            switch mode {
            case .inserted:
                InsertedFlashIndicator()
                    .transition(.opacity)
            case .transcribing:
                TranscribingRippleIndicator(startTime: transcribingStartTime)
                    .transition(.opacity)
            case .recording:
                Canvas(rendersAsynchronously: true) { context, size in
                    drawBars(context: &context, size: size)
                }
                .transition(.opacity)
            case .error:
                ErrorStateIndicator()
                    .transition(.opacity)
            case .idle:
                Color.clear
            }
        }
        .animation(.easeInOut(duration: 0.22), value: mode)
    }

    private func drawBars(context: inout GraphicsContext, size: CGSize) {
        let count = max(levels.count, 1)
        let activeWidth = waveWidth(for: size.width)
        let pitch = activeWidth / CGFloat(count)
        let barWidth = min(max(pitch * 0.38, 2.4), 3.6)
        let spacing = max(3.4, pitch - barWidth)
        let renderedWidth = (CGFloat(count) * barWidth) + (CGFloat(max(0, count - 1)) * spacing)
        let startX = (size.width - renderedWidth) * 0.5
        let minHeight = max(1.6, size.height * 0.04)
        let maxHeight = size.height * 0.90
        let midY = size.height / 2

        for index in levels.indices {
            let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
            let visual = visualLevel(for: levels[index])
            let barHeight = minHeight + ((maxHeight - minHeight) * visual)
            let x = startX + (CGFloat(index) * (barWidth + spacing))
            let rect = CGRect(
                x: x,
                y: midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            let path = Path(
                roundedRect: rect,
                cornerRadius: barWidth * 0.5,
                style: .continuous
            )

            context.opacity = leftFadeOpacity(for: progress)
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color.white.opacity(0.62), location: 0),
                        .init(color: Color.white.opacity(0.98), location: 0.5),
                        .init(color: Color.white.opacity(0.62), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }
    }

    private func waveWidth(for totalWidth: CGFloat) -> CGFloat {
        min(totalWidth * 0.82, 480)
    }

    private func visualLevel(for level: CGFloat) -> CGFloat {
        let noiseFloor: CGFloat = 0.035
        let speechPeak: CGFloat = 0.30
        let range = speechPeak - noiseFloor
        let normalized = max(0, (level - noiseFloor) / range)
        let clamped = min(normalized, 1.0)
        return min(pow(clamped, 0.85), 0.96)
    }

    private func leftFadeOpacity(for progress: CGFloat) -> Double {
        let fadeLength: CGFloat = 0.18
        if progress >= fadeLength { return 1.0 }
        let t = progress / fadeLength
        let eased = t * t * (3 - 2 * t)
        return Double(eased)
    }
}

private struct TranscribingRippleIndicator: View {
    let startTime: TimeInterval?

    private let barCount = 9
    private let barWidth: CGFloat = 3.4
    private let spacing: CGFloat = 7.0
    private let tint = Color(red: 0.58, green: 0.82, blue: 0.98)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let totalWidth = (CGFloat(barCount) * barWidth) + (CGFloat(barCount - 1) * spacing)
                let startX = (size.width - totalWidth) / 2
                let midY = size.height / 2
                let minHeight = max(3, size.height * 0.14)
                let maxHeight = size.height * 0.72

                let now = timeline.date.timeIntervalSinceReferenceDate
                let elapsed = startTime.map { max(0, now - $0) } ?? now

                for index in 0..<barCount {
                    let phase = sin(elapsed * 3.05 - Double(index) * 0.58)
                    let normalized = 0.22 + 0.78 * max(0, phase)
                    let h = minHeight + (maxHeight - minHeight) * CGFloat(normalized)
                    let x = startX + CGFloat(index) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: barWidth * 0.5,
                        style: .continuous
                    )

                    context.opacity = 0.50 + 0.48 * normalized
                    context.fill(
                        path,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: tint.opacity(0.60), location: 0),
                                .init(color: tint.opacity(1.0), location: 0.5),
                                .init(color: tint.opacity(0.60), location: 1),
                            ]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                }
            }
        }
    }
}

private struct ErrorStateIndicator: View {
    private let tint = Color(red: 0.93, green: 0.38, blue: 0.34)
    private let period: Double = 2.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * (2 * .pi / period)) + 1) / 2
            let fillOpacity = 0.62 + 0.20 * phase
            let shadowOpacity = 0.28 + 0.30 * phase
            let shadowRadius = 6.0 + 5.0 * phase

            Circle()
                .fill(tint.opacity(fillOpacity))
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(shadowOpacity), radius: shadowRadius)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct InsertedFlashIndicator: View {
    @State private var expand: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        GeometryReader { geo in
            let targetWidth = min(geo.size.width * 0.55, 320)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.95),
                            Color.white.opacity(0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: targetWidth * expand, height: 2.5)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .opacity(opacity)
                .task {
                    withAnimation(.easeOut(duration: 0.22)) {
                        expand = 1
                        opacity = 1
                    }
                    try? await Task.sleep(for: .milliseconds(450))
                    withAnimation(.easeIn(duration: 0.30)) {
                        opacity = 0
                    }
                }
        }
    }
}
