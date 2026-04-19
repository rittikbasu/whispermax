import SwiftUI

enum KeycapTheme {
    static let surface = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let highlight = Color.white.opacity(0.055)
    static let highlightPressed = Color.white.opacity(0.025)
    static let border = Color.white.opacity(0.09)
    static let borderPressed = Color.white.opacity(0.04)
}

struct KeycapGroup: View {
    var isPressed: Bool = false
    var scale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 5 * scale) {
            Keycap(
                label: "\u{2325}",
                sublabel: "option",
                width: 50 * scale,
                isPressed: isPressed,
                scale: scale
            )
            Keycap(
                label: nil,
                sublabel: nil,
                width: 170 * scale,
                isPressed: isPressed,
                scale: scale
            )
        }
    }
}

struct Keycap: View {
    let label: String?
    var sublabel: String?
    let width: CGFloat
    let isPressed: Bool
    var scale: CGFloat = 1.0

    private var height: CGFloat { 42 * scale }
    private var radius: CGFloat { 6 * scale }
    private var totalHeight: CGFloat { 46 * scale }
    private var labelSize: CGFloat { 16 * scale }
    private var sublabelSize: CGFloat { 8 * scale }
    private var pressOffset: CGFloat { 1.5 * scale }

    var body: some View {
        ZStack(alignment: .top) {
            keyFace
                .offset(y: isPressed ? pressOffset : 0)
        }
        .frame(width: width, height: totalHeight)
        .shadow(
            color: .black.opacity(isPressed ? 0.08 : 0.30),
            radius: (isPressed ? 0.5 : 2.5) * scale,
            y: (isPressed ? 0.5 : 2) * scale
        )
        .animation(.easeOut(duration: 0.10), value: isPressed)
    }

    private var keyFace: some View {
        ZStack {
            if let label {
                VStack(spacing: 1 * scale) {
                    Text(label)
                        .font(.system(size: labelSize, weight: .regular))
                        .foregroundStyle(.white.opacity(isPressed ? 0.50 : 0.72))

                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: sublabelSize, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(.white.opacity(isPressed ? 0.12 : 0.22))
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(KeycapTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(
                                        color: isPressed ? KeycapTheme.highlightPressed : KeycapTheme.highlight,
                                        location: 0
                                    ),
                                    .init(color: .clear, location: 0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            isPressed ? KeycapTheme.borderPressed : KeycapTheme.border,
                            lineWidth: 0.5
                        )
                )
        )
    }
}
