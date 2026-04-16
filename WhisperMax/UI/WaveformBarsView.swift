import SwiftUI

struct WaveformBarsView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let count = max(levels.count, 1)
            let activeWidth = activeWaveWidth(for: geometry.size.width)
            let pitch = activeWidth / CGFloat(count)
            let barWidth = min(max(pitch * 0.46, 1.9), 3.4)
            let spacing = max(1.7, pitch - barWidth)
            let renderedWidth = (CGFloat(count) * barWidth) + (CGFloat(max(0, count - 1)) * spacing)
            let startX = (geometry.size.width - renderedWidth) * 0.5
            let minHeight = max(1.4, geometry.size.height * 0.02)
            let maxHeight = geometry.size.height * 0.68

            Canvas(rendersAsynchronously: true) { context, size in
                for index in levels.indices {
                    let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
                    let opacity = edgeOpacity(for: progress)
                    let visualLevel = visualLevel(for: levels[index])
                    let barHeight = minHeight + ((maxHeight - minHeight) * visualLevel)
                    let rect = CGRect(
                        x: startX + (CGFloat(index) * (barWidth + spacing)),
                        y: (size.height - barHeight) * 0.5,
                        width: barWidth,
                        height: barHeight
                    )
                    let path = Path(
                        roundedRect: rect,
                        cornerRadius: barWidth * 0.5,
                        style: .continuous
                    )

                    context.opacity = opacity
                    context.fill(
                        path,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: Color.white.opacity(0.58), location: 0),
                                .init(color: Color.white.opacity(0.98), location: 0.50),
                                .init(color: Color.white.opacity(0.58), location: 1),
                            ]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                }
            }
        }
    }

    private func activeWaveWidth(for totalWidth: CGFloat) -> CGFloat {
        let preferredWidth = totalWidth * 0.57
        return max(250, min(preferredWidth, 470))
    }

    private func visualLevel(for level: CGFloat) -> CGFloat {
        let clamped = max(0, min(level, 1.0))
        return min(pow(clamped, 0.92), 0.94)
    }

    private func edgeOpacity(for progress: CGFloat) -> Double {
        let fadeLength: CGFloat = 0.20
        let distanceToNearestEdge = min(progress, 1 - progress)
        let normalized = min(max(distanceToNearestEdge / fadeLength, 0), 1)
        let eased = normalized * normalized * (3 - (2 * normalized))
        return Double(eased)
    }
}
