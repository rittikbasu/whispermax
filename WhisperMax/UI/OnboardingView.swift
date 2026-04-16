import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Theme

private enum OnboardingTheme {
    static let windowWidth: CGFloat = 540
    static let windowHeight: CGFloat = 520

    static let background = Color(red: 0.042, green: 0.042, blue: 0.052)
    static let cardFill = Color.white.opacity(0.028)
    static let cardBorder = Color.white.opacity(0.06)
    static let progressTrack = Color.white.opacity(0.06)
    static let progressFill = Color(red: 0.30, green: 0.46, blue: 0.77)
    static let grantedGreen = Color(red: 0.30, green: 0.78, blue: 0.52)
    static let pendingAmber = Color(red: 0.91, green: 0.67, blue: 0.27)
    static let mutedText = Color.white.opacity(0.40)
    static let bodyText = Color.white.opacity(0.58)
    static let headlineText = Color.white.opacity(0.92)
    static let buttonFill = Color.white.opacity(0.08)
    static let buttonBorder = Color.white.opacity(0.10)
    static let primaryButtonFill = Color(red: 0.30, green: 0.46, blue: 0.77)

    static let cardCornerRadius: CGFloat = 14
    static let slideSpring = Animation.spring(response: 0.5, dampingFraction: 0.86)
    static let contentAppear = Animation.easeOut(duration: 0.35)

    static let buttonWidth: CGFloat = 300

    // Keycap surface — shared so both keys read as the same material
    static let keySurface = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let keyHighlight = Color.white.opacity(0.055)
    static let keyHighlightPressed = Color.white.opacity(0.025)
    static let keyBorder = Color.white.opacity(0.09)
    static let keyBorderPressed = Color.white.opacity(0.04)
}

// MARK: - Styled App Name

private struct StyledAppName: View {
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: 0) {
            Text("whisper")
                .foregroundStyle(.white.opacity(0.50))
            Text("max")
                .foregroundStyle(.white.opacity(0.90))
        }
        .font(.system(size: size, weight: .medium))
        .tracking(-0.2)
    }
}

// MARK: - Window Resizer

private struct OnboardingWindowResizer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let targetSize = NSSize(
                width: OnboardingTheme.windowWidth,
                height: OnboardingTheme.windowHeight
            )

            window.minSize = targetSize
            window.maxSize = targetSize
            window.setContentSize(targetSize)

            if let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - targetSize.width / 2
                let y = screenFrame.midY - targetSize.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }

            window.styleMask.remove(.resizable)
            window.styleMask.remove(.miniaturizable)

            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.fullScreenNone)
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.isEnabled = false
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct OnboardingWindowRestorer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let defaultSize = NSSize(width: 1120, height: 840)
            window.minSize = NSSize(width: 1040, height: 760)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(defaultSize)

            if let screen = window.screen ?? NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - defaultSize.width / 2
                let y = screenFrame.midY - defaultSize.height / 2
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }

            window.styleMask.insert(.resizable)
            window.styleMask.insert(.miniaturizable)
            window.collectionBehavior.remove(.fullScreenNone)
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.isEnabled = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Root View

struct OnboardingView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        ZStack {
            OnboardingTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 44)

                StepIndicator(current: controller.onboardingStep)
                    .padding(.bottom, 32)

                ZStack {
                    DownloadCard()
                        .cardTransition(isActive: controller.onboardingStep == .download, direction: .backward)

                    PermissionsCard()
                        .cardTransition(isActive: controller.onboardingStep == .permissions, direction: controller.onboardingStep.rawValue > OnboardingStep.permissions.rawValue ? .backward : .forward)

                    ReadyCard()
                        .cardTransition(isActive: controller.onboardingStep == .ready, direction: .forward)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnboardingWindowResizer())
        .onAppear {
            controller.startSimulatedDownload()
        }
    }
}

// MARK: - Step Indicator

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule(style: .continuous)
                    .fill(step.rawValue <= current.rawValue
                          ? OnboardingTheme.progressFill
                          : OnboardingTheme.progressTrack)
                    .frame(width: step == current ? 28 : 8, height: 4)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
            }
        }
    }
}

// MARK: - Card 1: Download

private struct DownloadCard: View {
    @Environment(AppController.self) private var controller

    @State private var headlineVisible = false
    @State private var bodyVisible = false
    @State private var progressVisible = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .center, spacing: 20) {
                // Brand lockup: mark + wordmark
                VStack(spacing: 8) {
                    Image("WhisperMaxMark")
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 22)
                        .foregroundStyle(.white.opacity(0.50))

                    StyledAppName(size: 14)
                }

                VStack(spacing: 12) {
                    Text("whisper, pushed to the max")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.8)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(OnboardingTheme.headlineText)

                    Text("One model. On your Mac. No subscription.")
                        .font(.system(size: 15, weight: .regular))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .foregroundStyle(OnboardingTheme.bodyText)
                }
            }
            .opacity(headlineVisible ? 1 : 0)
            .offset(y: headlineVisible ? 0 : 12)

            Spacer()

            VStack(spacing: 16) {
                DownloadProgressBar(progress: controller.downloadProgress)

                HStack {
                    Text(downloadStatusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OnboardingTheme.mutedText)

                    Spacer()

                    Text(downloadSizeText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(OnboardingTheme.mutedText)
                }
            }
            .opacity(progressVisible ? 1 : 0)
            .offset(y: progressVisible ? 0 : 8)

            Spacer().frame(height: 32)

            OnboardingButton(
                title: controller.isDownloadComplete ? "Continue" : "Downloading\u{2026}",
                isPrimary: controller.isDownloadComplete,
                isEnabled: controller.isDownloadComplete,
                action: controller.advanceOnboarding
            )
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(OnboardingTheme.contentAppear.delay(0.1)) {
                headlineVisible = true
            }
            withAnimation(OnboardingTheme.contentAppear.delay(0.3)) {
                progressVisible = true
            }
        }
    }

    private var downloadStatusText: String {
        controller.isDownloadComplete ? "Speech model ready" : "Downloading speech model\u{2026}"
    }

    private var downloadSizeText: String {
        let downloaded = controller.downloadProgress * 1624
        if controller.isDownloadComplete {
            return "1.6 GB"
        }
        return String(format: "%.0f MB / 1.6 GB", downloaded)
    }
}

private struct DownloadProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(OnboardingTheme.progressTrack)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                OnboardingTheme.progressFill,
                                OnboardingTheme.progressFill.opacity(0.7),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geo.size.width * CGFloat(progress)))
                    .animation(.easeOut(duration: 0.15), value: progress)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Card 2: Permissions

private struct PermissionsCard: View {
    @Environment(AppController.self) private var controller

    @State private var headerVisible = false
    @State private var micCardVisible = false
    @State private var accessCardVisible = false
    @State private var pollingTask: Task<Void, Never>?
    @State private var notificationObserver: NSObjectProtocol?

    private var micGranted: Bool { controller.microphoneGranted }
    private var accessGranted: Bool { controller.accessibilityGranted }
    private var canContinue: Bool { micGranted && accessGranted }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .center, spacing: 10) {
                Text("Two quick permissions")
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(OnboardingTheme.headlineText)
                    .opacity(headerVisible ? 1 : 0)
                    .offset(y: headerVisible ? 0 : 12)

                Text("Everything runs on-device. These stay local.")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(OnboardingTheme.bodyText)
                    .opacity(headerVisible ? 1 : 0)
                    .offset(y: headerVisible ? 0 : 10)
            }

            Spacer().frame(height: 36)

            VStack(spacing: 12) {
                PermissionCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: micGranted ? "Granted" : "To hear your voice.",
                    isGranted: micGranted,
                    buttonTitle: "Grant Access",
                    action: {
                        Task {
                            controller.microphoneGranted = await controller.permissionsManager.requestMicrophoneAccess()
                        }
                    }
                )
                .opacity(micCardVisible ? 1 : 0)
                .offset(y: micCardVisible ? 0 : 10)

                PermissionCard(
                    icon: "accessibility",
                    title: "Accessibility",
                    subtitle: accessGranted ? "Granted" : "To type text into any app.",
                    isGranted: accessGranted,
                    isActive: micGranted,
                    buttonTitle: "Open Settings",
                    action: {
                        controller.permissionsManager.promptForAccessibility()
                        controller.openAccessibilitySettings()
                    }
                )
                .opacity(accessCardVisible ? 1 : 0)
                .offset(y: accessCardVisible ? 0 : 10)
            }

            Spacer()

            OnboardingButton(
                title: "Continue",
                isPrimary: canContinue,
                isEnabled: canContinue,
                action: controller.advanceOnboarding
            )
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(OnboardingTheme.contentAppear.delay(0.1)) {
                headerVisible = true
            }
            withAnimation(OnboardingTheme.contentAppear.delay(0.2)) {
                micCardVisible = true
            }
            withAnimation(OnboardingTheme.contentAppear.delay(0.35)) {
                accessCardVisible = true
            }
            startPermissionMonitoring()
        }
        .onDisappear {
            pollingTask?.cancel()
            if let observer = notificationObserver {
                DistributedNotificationCenter.default().removeObserver(observer)
            }
        }
    }

    private func checkAccessibility() {
        let granted = AXIsProcessTrusted()
        if granted != controller.accessibilityGranted {
            controller.accessibilityGranted = granted
        }
    }

    private func startPermissionMonitoring() {
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { _ in
            checkAccessibility()
        }

        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                checkAccessibility()
            }
        }
    }
}

private struct PermissionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isGranted: Bool
    var isActive: Bool = true
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isGranted ? OnboardingTheme.grantedGreen : (isActive ? .white.opacity(0.7) : .white.opacity(0.25)))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isGranted ? OnboardingTheme.grantedGreen.opacity(0.12) : Color.white.opacity(0.04))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? OnboardingTheme.headlineText : .white.opacity(0.30))

                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(isGranted ? OnboardingTheme.grantedGreen.opacity(0.8) : (isActive ? OnboardingTheme.mutedText : .white.opacity(0.18)))
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(OnboardingTheme.grantedGreen)
                    .transition(.scale.combined(with: .opacity))
            } else if isActive {
                Button(action: action) {
                    Text(buttonTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(OnboardingTheme.buttonFill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(OnboardingTheme.buttonBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: OnboardingTheme.cardCornerRadius, style: .continuous)
                .fill(OnboardingTheme.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingTheme.cardCornerRadius, style: .continuous)
                        .stroke(OnboardingTheme.cardBorder, lineWidth: 1)
                )
        )
        .opacity(isActive ? 1 : 0.45)
        .animation(.easeOut(duration: 0.25), value: isGranted)
        .animation(.easeOut(duration: 0.25), value: isActive)
    }
}

// MARK: - Card 3: Ready

private struct ReadyCard: View {
    @Environment(AppController.self) private var controller

    @State private var keycapVisible = false
    @State private var instructionVisible = false
    @State private var buttonVisible = false
    @State private var keycapPressed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                KeycapGroup(isPressed: keycapPressed)
                    .opacity(keycapVisible ? 1 : 0)
                    .scaleEffect(keycapVisible ? 1 : 0.90)

                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Hold")
                            .foregroundStyle(OnboardingTheme.headlineText)
                        Text("\u{2325} Space")
                            .foregroundStyle(.white)
                    }
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)

                    Text("to start dictating. Release to transcribe.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(OnboardingTheme.bodyText)
                }
                .opacity(instructionVisible ? 1 : 0)
                .offset(y: instructionVisible ? 0 : 10)

                Text("whispermax lives in your menu bar")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.30))
                    .opacity(instructionVisible ? 1 : 0)
            }

            Spacer()

            OnboardingButton(
                title: "Get Started",
                isPrimary: true,
                isEnabled: true,
                action: controller.completeOnboarding
            )
            .opacity(buttonVisible ? 1 : 0)
            .offset(y: buttonVisible ? 0 : 8)
        }
        .padding(.top, 8)
        .onAppear {
            withAnimation(OnboardingTheme.slideSpring.delay(0.15)) {
                keycapVisible = true
            }
            withAnimation(OnboardingTheme.contentAppear.delay(0.3)) {
                instructionVisible = true
            }
            withAnimation(OnboardingTheme.contentAppear.delay(0.45)) {
                buttonVisible = true
            }
            startKeycapLoop()
        }
    }

    private func startKeycapLoop() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))

            while !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.08)) {
                    keycapPressed = true
                }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.16)) {
                    keycapPressed = false
                }
                try? await Task.sleep(for: .seconds(2.2))
            }
        }
    }
}

// MARK: - Keycaps

private struct KeycapGroup: View {
    let isPressed: Bool

    var body: some View {
        HStack(spacing: 5) {
            Keycap(label: "\u{2325}", sublabel: "option", width: 50, isPressed: isPressed)
            Keycap(label: nil, sublabel: nil, width: 170, isPressed: isPressed)
        }
    }
}

private struct Keycap: View {
    let label: String?
    var sublabel: String?
    let width: CGFloat
    let isPressed: Bool

    private let height: CGFloat = 42
    private let radius: CGFloat = 6
    private let totalHeight: CGFloat = 46 // fixed frame prevents layout shift

    var body: some View {
        ZStack(alignment: .top) {
            keyFace
                .offset(y: isPressed ? 1.5 : 0)
        }
        .frame(width: width, height: totalHeight)
        .shadow(
            color: .black.opacity(isPressed ? 0.08 : 0.30),
            radius: isPressed ? 0.5 : 2.5,
            y: isPressed ? 0.5 : 2
        )
        .animation(.easeOut(duration: 0.10), value: isPressed)
    }

    private var keyFace: some View {
        ZStack {
            if let label {
                VStack(spacing: 1) {
                    Text(label)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(isPressed ? 0.50 : 0.72))

                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: 8, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(.white.opacity(isPressed ? 0.12 : 0.22))
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(OnboardingTheme.keySurface)
                .overlay(
                    // Surface sheen — uniform across all key widths
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: isPressed ? OnboardingTheme.keyHighlightPressed : OnboardingTheme.keyHighlight, location: 0),
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
                            isPressed ? OnboardingTheme.keyBorderPressed : OnboardingTheme.keyBorder,
                            lineWidth: 0.5
                        )
                )
        )
    }
}

// MARK: - Shared Components

private struct OnboardingButton: View {
    let title: String
    let isPrimary: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isPrimary ? .white : .white.opacity(0.50))
                .frame(width: OnboardingTheme.buttonWidth)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isPrimary ? OnboardingTheme.primaryButtonFill : OnboardingTheme.buttonFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isPrimary ? OnboardingTheme.primaryButtonFill.opacity(0.5) : OnboardingTheme.buttonBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(OnboardingButtonPressStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.40)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

private struct OnboardingButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Card Transition

private enum SlideDirection {
    case forward, backward
}

private struct CardTransitionModifier: ViewModifier {
    let isActive: Bool
    let direction: SlideDirection

    func body(content: Content) -> some View {
        content
            .offset(x: isActive ? 0 : (direction == .forward ? 80 : -80))
            .opacity(isActive ? 1 : 0)
            .animation(OnboardingTheme.slideSpring, value: isActive)
            .allowsHitTesting(isActive)
    }
}

private extension View {
    func cardTransition(isActive: Bool, direction: SlideDirection) -> some View {
        modifier(CardTransitionModifier(isActive: isActive, direction: direction))
    }
}
