import SwiftUI

struct WaveformBarsView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let displayLevels = sampledLevels(forWidth: geometry.size.width)
            let count = max(displayLevels.count, 1)
            let spacing = CGFloat(0.9)
            let totalSpacing = CGFloat(count - 1) * spacing
            let rawBarWidth = (geometry.size.width - totalSpacing) / CGFloat(count)
            let barWidth = min(max(rawBarWidth, 1.2), 2.2)
            let minimumHeight = max(2, geometry.size.height * 0.015)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(displayLevels.indices, id: \.self) { index in
                    let visualLevel = normalizedLevel(for: displayLevels[index])

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.90),
                                    Color.white.opacity(0.70),
                                    Color.white.opacity(0.22),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: barWidth,
                            height: max(minimumHeight, geometry.size.height * visualLevel)
                        )
                        .animation(.easeOut(duration: 0.04), value: visualLevel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .mask(edgeFadeMask)
        }
    }

    private var edgeFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .white.opacity(0.28), location: 0.08),
                .init(color: .white, location: 0.20),
                .init(color: .white, location: 0.80),
                .init(color: .white.opacity(0.28), location: 0.92),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func sampledLevels(forWidth width: CGFloat) -> [CGFloat] {
        let barCount = max(100, min(260, Int(width / 3.2)))
        guard !levels.isEmpty else {
            return Array(repeating: 0.005, count: barCount)
        }

        let bucketSize = Double(levels.count) / Double(barCount)
        var samples: [CGFloat] = []
        samples.reserveCapacity(barCount)

        for barIndex in 0..<barCount {
            let start = Int(floor(Double(barIndex) * bucketSize))
            let end = max(start + 1, Int(ceil(Double(barIndex + 1) * bucketSize)))
            let slice = levels[start..<min(end, levels.count)]
            let average = slice.reduce(0, +) / CGFloat(slice.count)
            let peak = slice.max() ?? average
            samples.append((average * 0.40) + (peak * 0.60))
        }

        return smooth(samples)
    }

    private func smooth(_ values: [CGFloat]) -> [CGFloat] {
        guard values.count > 2 else { return values }

        var smoothed = values
        for index in values.indices {
            let prev = values[max(0, index - 1)]
            let curr = values[index]
            let next = values[min(values.count - 1, index + 1)]
            smoothed[index] = (prev * 0.20) + (curr * 0.60) + (next * 0.20)
        }
        return smoothed
    }

    private func normalizedLevel(for level: CGFloat) -> CGFloat {
        let clamped = max(0, min(level, 1.0))
        // Gate low-level noise then re-normalize, creating dramatic contrast
        let gated = max(0, clamped - 0.06) / 0.94
        let expanded = pow(gated, 0.62)
        return max(0.003, min(expanded, 0.96))
    }
}
