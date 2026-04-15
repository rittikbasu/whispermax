import SwiftUI

struct WaveformBarsView: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geometry in
            let displayLevels = sampledLevels(forWidth: geometry.size.width)
            let count = max(displayLevels.count, 1)
            let spacing = CGFloat(1.8)
            let totalSpacing = CGFloat(count - 1) * spacing
            let rawBarWidth = (geometry.size.width - totalSpacing) / CGFloat(count)
            let barWidth = min(max(rawBarWidth, 2.0), 3.8)
            let minimumHeight = max(3, geometry.size.height * 0.024)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(displayLevels.indices, id: \.self) { index in
                    let visualLevel = normalizedLevel(for: displayLevels[index])

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.88),
                                    Color.white.opacity(0.68),
                                    Color.white.opacity(0.28),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(
                            width: barWidth,
                            height: max(minimumHeight, geometry.size.height * visualLevel)
                        )
                        .animation(.easeOut(duration: 0.055), value: visualLevel)
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
                .init(color: .white.opacity(0.38), location: 0.11),
                .init(color: .white, location: 0.23),
                .init(color: .white, location: 0.77),
                .init(color: .white.opacity(0.38), location: 0.89),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func sampledLevels(forWidth width: CGFloat) -> [CGFloat] {
        let barCount = max(72, min(116, Int(width / 6.15)))
        guard !levels.isEmpty else {
            return Array(repeating: 0.01, count: barCount)
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
            samples.append((average * 0.62) + (peak * 0.38))
        }

        return smooth(samples)
    }

    private func smooth(_ values: [CGFloat]) -> [CGFloat] {
        guard values.count > 2 else {
            return values
        }

        var smoothed = values

        for index in values.indices {
            let previous = values[max(0, index - 1)]
            let current = values[index]
            let next = values[min(values.count - 1, index + 1)]
            smoothed[index] = (previous * 0.23) + (current * 0.54) + (next * 0.23)
        }

        return smoothed
    }

    private func normalizedLevel(for level: CGFloat) -> CGFloat {
        let clampedLevel = max(0, min(level, 1.0))
        let easedLevel = pow(clampedLevel, 0.92)
        return max(0.018, min(easedLevel, 0.96))
    }
}
