import SwiftUI

private enum Theme {
    static let shell = Color(red: 0.03, green: 0.03, blue: 0.038)
    static let shellEdge = Color.white.opacity(0.07)
    static let panel = Color.white.opacity(0.022)
    static let selectedFill = Color(red: 0.14, green: 0.18, blue: 0.27)
    static let selectedStroke = Color(red: 0.30, green: 0.46, blue: 0.77).opacity(0.34)
    static let dictionaryAccent = Color(red: 0.49, green: 0.68, blue: 0.98)
    static let dictionaryAccentFill = Color(red: 0.16, green: 0.21, blue: 0.31)
    static let dictionaryAccentStroke = Color(red: 0.36, green: 0.50, blue: 0.80).opacity(0.48)
    static let updateAccent = Color(red: 0.88, green: 0.73, blue: 0.29)
    static let updateFill = Color(red: 0.17, green: 0.14, blue: 0.08).opacity(0.42)
    static let updateStroke = Color(red: 0.89, green: 0.73, blue: 0.29).opacity(0.22)
    static let sidebarDivider = Color.white.opacity(0.06)
    static let contentTop = Color(red: 0.051, green: 0.054, blue: 0.070)
    static let contentBottom = Color(red: 0.034, green: 0.036, blue: 0.048)
    static let historyBoxTop = Color(red: 0.026, green: 0.028, blue: 0.037)
    static let historyBoxBottom = Color(red: 0.021, green: 0.022, blue: 0.030)
    static let historyBoxBorder = Color.white.opacity(0.05)
    static let transcriptText = Color(red: 0.80, green: 0.81, blue: 0.86)
    static let transcriptMeta = Color.white.opacity(0.24)
    static let transcriptTimestamp = Color.white.opacity(0.30)
    static let transcriptMarker = Color(red: 0.22, green: 0.72, blue: 0.67)
    static let actionIdle = Color.white.opacity(0.24)
}

private enum Layout {
    static let contentSidePadding: CGFloat = 46
    static let maxContentWidth: CGFloat = 1320
    static let settingsContentWidth: CGFloat = 760
    static let headerTopPadding: CGFloat = 66
    static let headerBottomPadding: CGFloat = 46
    static let contentBottomPadding: CGFloat = 28
    static let historySpacing: CGFloat = 18
    static let historyInitialViewportCount = 60
    static let historyBatchCount = 80
}

struct MainWindowView: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        ZStack {
            if controller.hasCompletedOnboarding {
                mainAppShell
                    .frame(minWidth: 1040, minHeight: 760)
                    .background(OnboardingWindowRestorer())
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: controller.hasCompletedOnboarding)
        .background(WindowChromeConfigurator())
    }

    private var mainAppShell: some View {
        ZStack {
            Theme.shell.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarRail()

                Rectangle()
                    .fill(Theme.sidebarDivider)
                    .frame(width: 1)

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
    }
}

// MARK: - Sidebar

private struct SidebarRail: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                AppGlyph()
                    .padding(.top, 48)
                    .padding(.bottom, 28)

                SidebarButton(
                    systemName: "house",
                    isSelected: controller.sidebarSelection == .home,
                    action: { controller.sidebarSelection = .home }
                )
                SidebarButton(
                    systemName: "book.closed",
                    isSelected: controller.sidebarSelection == .dictionary,
                    action: { controller.sidebarSelection = .dictionary }
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle()
                .fill(Theme.sidebarDivider)
                .frame(height: 1)

            SidebarButton(
                systemName: "gearshape",
                isSelected: controller.sidebarSelection == .settings,
                action: { controller.sidebarSelection = .settings }
            )
            .padding(.vertical, 18)
        }
        .frame(width: 80)
        .background(Color.black.opacity(0.26))
    }
}

private struct AppGlyph: View {
    var body: some View {
        Image("WhisperMaxMark")
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 46, height: 28)
            .foregroundStyle(.white.opacity(0.96))
    }
}

private struct SidebarButton: View {
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.48))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isSelected ? Theme.selectedFill : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(isSelected ? Theme.selectedStroke : .clear, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Content Area

private struct MainContentArea: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.contentTop, Theme.contentBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Group {
                switch controller.sidebarSelection {
                case .home:
                    pinnedHeaderLayout {
                        HistorySection()
                            .frame(maxHeight: .infinity)
                    }
                case .dictionary:
                    pinnedHeaderLayout {
                        DictionarySection()
                            .frame(maxHeight: .infinity)
                    }
                case .settings:
                    settingsScrollLayout
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: controller.sidebarSelection)
    }

    @ViewBuilder
    private func pinnedHeaderLayout<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: controller.needsSetup ? 26 : 0) {
                WindowHeader()

                if controller.needsSetup {
                    PermissionSetupPanel()
                }
            }
            .padding(.top, Layout.headerTopPadding)
            .padding(.bottom, Layout.headerBottomPadding)

            content()
        }
        .frame(maxWidth: Layout.maxContentWidth, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Layout.contentSidePadding)
        .padding(.bottom, Layout.contentBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsScrollLayout: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                WindowHeader()
                    .padding(.top, Layout.headerTopPadding)
                    .padding(.bottom, Layout.headerBottomPadding)

                SettingsSection()
                    .padding(.bottom, 40)
            }
            .frame(maxWidth: Layout.settingsContentWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.contentSidePadding)
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.035),
                    .init(color: .black, location: 0.965),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Header

private struct WindowHeader: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(headerTitle)
                    .font(.system(size: 41, weight: .medium))
                    .tracking(-1.3)
                    .foregroundStyle(.white)

                Text(headerSubtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 16)

            if controller.shouldShowHomeUpdatePill, let availableUpdate = controller.availableUpdate {
                UpdateAvailablePill(
                    version: availableUpdate.version,
                    action: controller.openAvailableUpdate
                )
                .padding(.top, 2)
            }
        }
    }

    private var headerTitle: String {
        switch controller.sidebarSelection {
        case .home:
            let hour = Calendar.current.component(.hour, from: Date())
            switch hour {
            case 5..<12: return "Good morning"
            case 12..<17: return "Good afternoon"
            default: return "Good evening"
            }
        case .dictionary:
            return "Dictionary"
        case .settings:
            return "Settings"
        }
    }

    private var headerSubtitle: String {
        switch controller.sidebarSelection {
        case .home:
            return controller.homeSubtitle
        case .dictionary:
            return "Add the product names, phrases, and uncommon terms you want whispermax to hear correctly."
        case .settings:
            return "Your hotkey, model, and permissions."
        }
    }
}

private struct UpdateAvailablePill: View {
    let version: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(Theme.updateAccent)
                    .frame(width: 7, height: 7)

                Text("update available")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))

                Text(version)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.44))
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? Theme.updateFill.opacity(1.12) : Theme.updateFill)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(isHovering ? Theme.updateStroke.opacity(1.25) : Theme.updateStroke, lineWidth: 1)
                    )
            )
            .scaleEffect(isHovering ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .help("Open update details")
    }
}

// MARK: - Permissions

private struct PermissionSetupPanel: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("SETUP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.5))

                Text("Finish permissions for automatic dictation.")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Microphone lets whispermax record. Accessibility lets it insert text into other apps.")
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
                    action: controller.beginAccessibilityPermissionFlow
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(PanelCardBackground(cornerRadius: 16))
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
                .fill(isGranted ? Color(red: 0.30, green: 0.78, blue: 0.52) : Color(red: 0.91, green: 0.67, blue: 0.27))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
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
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.024))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.045), lineWidth: 1)
                )
        )
    }
}

// MARK: - History

private struct HistorySection: View {
    @Environment(AppController.self) private var controller

    private var entries: [TranscriptEntry] {
        controller.filteredHistory
    }

    private var countText: String {
        String(entries.count)
    }

    private var historyResetToken: String {
        controller.searchText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.historySpacing) {
            SectionHeader(
                title: "TRANSCRIPTIONS",
                countText: countText,
                searchText: Bindable(controller).searchText
            )

            VirtualizedHistoryList(entries: entries)
                .id(historyResetToken)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.historyBoxTop, Theme.historyBoxBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Theme.historyBoxBorder, lineWidth: 1)
                        )
                )
                .overlay(alignment: .bottomTrailing) {
                    if let pendingTranscriptDeletion = controller.pendingTranscriptDeletion {
                        DeleteUndoToast(
                            token: pendingTranscriptDeletion.token,
                            title: pendingTranscriptDeletion.title,
                            undoAction: controller.undoPendingDeletion
                        )
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.18), value: controller.pendingTranscriptDeletion)
    }
}

private struct VirtualizedHistoryList: View {
    let entries: [TranscriptEntry]

    @State private var visibleCount = Layout.historyInitialViewportCount

    private var effectiveVisibleCount: Int {
        min(visibleCount, entries.count)
    }

    private var visibleEntries: [TranscriptEntry] {
        Array(entries.prefix(effectiveVisibleCount))
    }

    private var hasMoreEntries: Bool {
        effectiveVisibleCount < entries.count
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            LazyVStack(spacing: 0) {
                if entries.isEmpty {
                    EmptyHistoryState()
                } else {
                    ForEach(visibleEntries) { entry in
                        HistoryRow(entry: entry)

                        if entry.id != visibleEntries.last?.id {
                            FadingDivider()
                        }
                    }

                    if hasMoreEntries {
                        HistoryViewportSentinel(loadMore: loadMore)
                    }
                }
            }
            .padding(.vertical, entries.isEmpty ? 0 : 10)
        }
        .onAppear {
            resetViewport()
        }
        .onChange(of: entries.count) {
            syncViewportToEntryCount()
        }
    }

    private func resetViewport() {
        visibleCount = min(Layout.historyInitialViewportCount, entries.count)
    }

    private func syncViewportToEntryCount() {
        guard !entries.isEmpty else {
            visibleCount = 0
            return
        }

        visibleCount = min(max(visibleCount, Layout.historyInitialViewportCount), entries.count)
    }

    private func loadMore() {
        guard visibleCount < entries.count else {
            return
        }

        visibleCount = min(visibleCount + Layout.historyBatchCount, entries.count)
    }
}

private struct HistoryViewportSentinel: View {
    let loadMore: () -> Void

    var body: some View {
        Color.clear
            .frame(height: 1)
            .onAppear {
                Task { @MainActor in
                    loadMore()
                }
            }
    }
}

private struct SectionHeader: View {
    let title: String
    let countText: String?
    private let searchBinding: Binding<String>?

    init(title: String, countText: String? = nil) {
        self.title = title
        self.countText = countText
        self.searchBinding = nil
    }

    init(title: String, countText: String? = nil, searchText: Binding<String>) {
        self.title = title
        self.countText = countText
        self.searchBinding = searchText
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(2.4)
                    .foregroundStyle(.white.opacity(0.36))

                if let countText {
                    Text("·")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.18))

                    Text(countText)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .tracking(1.4)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.22))
                }
            }

            if let searchBinding {
                Spacer()
                SearchField(text: searchBinding)
                    .frame(width: 268)
            }
        }
    }
}

private struct FadingDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.white.opacity(0.06), location: 0.10),
                        .init(color: Color.white.opacity(0.06), location: 0.90),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

private struct EmptyHistoryState: View {
    @Environment(AppController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(emptyStateTitle)
                .font(.system(size: 24, weight: .medium))
                .tracking(-0.5)
                .foregroundStyle(.white.opacity(0.86))

            Text(emptyStateBody)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.38))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
    }

    private var emptyStateTitle: String {
        let trimmedQuery = controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedQuery.isEmpty ? "No transcriptions yet" : "No matching transcriptions"
    }

    private var emptyStateBody: String {
        let trimmedQuery = controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedQuery.isEmpty {
            return "Try a different search term."
        }

        if controller.needsSetup {
            return "Finish setup above, then press \(controller.hotkeyInstructionText) to start recording."
        }

        return "Press \(controller.hotkeyInstructionText), talk, and your transcriptions will appear here."
    }
}

private struct HistoryRow: View {
    @Environment(AppController.self) private var controller

    let entry: TranscriptEntry

    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Theme.transcriptMarker)
                        .frame(width: 7, height: 7)

                    Text(compactTimestamp(entry.createdAt))
                        .font(.system(size: 11, weight: .regular))
                        .tracking(1.6)
                        .monospacedDigit()
                        .foregroundStyle(Theme.transcriptTimestamp)
                }

                Text(entry.text)
                    .font(.system(size: 15, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.transcriptText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)

                HistoryRowMetadata(
                    wordCountText: wordCountText,
                    durationText: formattedDurationText,
                    modelText: entry.modelName
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HistoryRowActions(
                showCopied: showCopied,
                copyAction: copyEntry,
                deleteAction: { controller.deleteEntry(entry) }
            )
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .contentShape(Rectangle())
    }

    private var wordCount: Int {
        entry.text.split(separator: " ").count
    }

    private var wordCountText: String {
        wordCount == 1 ? "1 word" : "\(wordCount) words"
    }

    private var formattedDurationText: String {
        if entry.duration < 10 {
            return String(format: "%.1fs", entry.duration)
        }

        return "\(Int(entry.duration.rounded()))s"
    }

    private func compactTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let month = calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1].uppercased()
        let day = calendar.component(.day, from: date)
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        return "\(month) \(day) \u{00B7} \(timeFormatter.string(from: date))"
    }

    private func copyEntry() {
        controller.copy(entry)
        showCopied = true

        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            showCopied = false
        }
    }

}

private struct HistoryRowMetadata: View {
    let wordCountText: String
    let durationText: String
    let modelText: String

    var body: some View {
        HStack(spacing: 14) {
            metadataText(wordCountText)
            MetadataDot()
            metadataText("\(durationText) audio")
                .monospacedDigit()
            MetadataDot()
            metadataText(modelText)
        }
        .lineLimit(1)
    }

    private func metadataText(_ text: String) -> Text {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Theme.transcriptMeta)
    }
}

private struct MetadataDot: View {
    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 3, height: 3)
    }
}

private struct HistoryRowActions: View {
    let showCopied: Bool
    let copyAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HistoryActionButton(
                normalSymbol: "doc.on.doc",
                activeSymbol: "checkmark",
                isActive: showCopied,
                activeTint: Color(red: 0.30, green: 0.78, blue: 0.52),
                action: copyAction
            )
            .help("Copy to clipboard")

            HistoryActionButton(
                normalSymbol: "trash",
                activeSymbol: "trash.fill",
                isActive: false,
                activeTint: Color(red: 0.93, green: 0.38, blue: 0.34),
                action: deleteAction
            )
            .help("Delete transcription")
        }
        .frame(width: 54, alignment: .trailing)
    }
}

private struct HistoryActionButton: View {
    let normalSymbol: String
    let activeSymbol: String
    let isActive: Bool
    let activeTint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: normalSymbol)
                    .opacity(isActive ? 0 : 1)

                Image(systemName: activeSymbol)
                    .opacity(isActive ? 1 : 0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isActive ? activeTint : Theme.actionIdle)
            .frame(width: 14, height: 14)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: isActive)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dictionary

private struct DictionarySection: View {
    @Environment(AppController.self) private var controller

    @State private var queryText = ""

    private var entries: [WordDictionaryEntry] {
        controller.filteredWordDictionary(matching: queryText)
    }

    private var trimmedQuery: String {
        queryText.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddQuery: Bool {
        controller.canAddWordDictionaryEntry(queryText)
    }

    private var isExactMatch: Bool {
        controller.containsWordDictionaryEntry(queryText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.historySpacing) {
            SectionHeader(
                title: "DICTIONARY",
                countText: String(controller.wordDictionary.count)
            )

            VStack(spacing: 0) {
                DictionaryInputRow(
                    queryText: $queryText,
                    addButtonTitle: addButtonTitle,
                    canAddQuery: canAddQuery,
                    addAction: addCurrentQuery
                )

                DictionaryInputDivider()

                if entries.isEmpty {
                    DictionaryEmptyState(
                        queryText: trimmedQuery,
                        canAddQuery: canAddQuery,
                        addAction: addTerm
                    )
                } else {
                    ScrollView(showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                DictionaryRow(entry: entry)

                                if entry.id != entries.last?.id {
                                    FadingDivider()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.historyBoxTop, Theme.historyBoxBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Theme.historyBoxBorder, lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addButtonTitle: String {
        if trimmedQuery.isEmpty {
            return "Add"
        }

        return isExactMatch ? "Added" : "Add"
    }

    private func addCurrentQuery() {
        addTerm(trimmedQuery)
    }

    private func addTerm(_ term: String) {
        guard controller.canAddWordDictionaryEntry(term) else {
            return
        }

        controller.addWordDictionaryEntry(term)
        queryText = ""
    }
}

private struct DictionaryInputRow: View {
    @Binding var queryText: String

    let addButtonTitle: String
    let canAddQuery: Bool
    let addAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.032))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Color.white.opacity(0.055), lineWidth: 1)
                    )

                Image(systemName: "book.closed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
            }
            .frame(width: 36, height: 36)

            TextField(
                "",
                text: $queryText,
                prompt: Text("Search or add a word or phrase…")
                    .foregroundStyle(.white.opacity(0.22))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.white.opacity(0.86))
            .onSubmit(addAction)

            Button(addButtonTitle, action: addAction)
                .buttonStyle(DictionaryAddButtonStyle(isEnabled: canAddQuery))
                .disabled(!canAddQuery)
        }
        .padding(.horizontal, 22)
        .frame(height: 76)
    }
}

private struct DictionaryInputDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.055))
            .frame(height: 0.5)
    }
}

private struct DictionaryRow: View {
    @Environment(AppController.self) private var controller

    let entry: WordDictionaryEntry

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(entry.text)
                .font(.system(size: 18, weight: .medium))
                .tracking(-0.2)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HistoryActionButton(
                normalSymbol: "trash",
                activeSymbol: "trash.fill",
                isActive: false,
                activeTint: Color(red: 0.93, green: 0.38, blue: 0.34),
                action: { controller.deleteWordDictionaryEntry(entry) }
            )
            .help("Remove from dictionary")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 21)
    }
}

private struct DictionaryEmptyState: View {
    let queryText: String
    let canAddQuery: Bool
    let addAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 29, weight: .medium))
                    .tracking(-0.9)
                    .foregroundStyle(.white.opacity(0.9))

                Text(bodyText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.40))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            if queryText.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("TRY THESE FIRST")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(1.8)
                        .foregroundStyle(.white.opacity(0.28))

                    HStack(spacing: 10) {
                        DictionaryExampleChip(text: "Codex", addAction: addAction)
                        DictionaryExampleChip(text: "Claude Code", addAction: addAction)
                        DictionaryExampleChip(text: "SQLite", addAction: addAction)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .padding(.horizontal, 22)
        .padding(.vertical, 30)
    }

    private var title: String {
        queryText.isEmpty ? "Start with the words whispermax misses" : "No matching entries"
    }

    private var bodyText: String {
        if queryText.isEmpty {
            return "Add product names, people, commands, and uncommon phrases. whispermax will use them as spelling hints during local transcription."
        }

        return canAddQuery
            ? "Press Add above to save this term to your dictionary."
            : "Try a different search term."
    }
}

private struct DictionaryExampleChip: View {
    let text: String
    let addAction: (String) -> Void

    var body: some View {
        Button {
            addAction(text)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.dictionaryAccent.opacity(0.9))

                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
            }
            .padding(.horizontal, 13)
            .frame(height: 31)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.065), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DictionaryAddButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
                isEnabled
                    ? .white.opacity(configuration.isPressed ? 0.84 : 0.96)
                    : .white.opacity(0.44)
            )
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isEnabled
                            ? Theme.dictionaryAccentFill.opacity(configuration.isPressed ? 0.92 : 1)
                            : Color.white.opacity(0.04)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isEnabled ? Theme.dictionaryAccentStroke : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private struct DeleteUndoToast: View {
    let token: UUID
    let title: String
    let undoAction: () -> Void

    @State private var progress: CGFloat = 1

    private let progressAnimationDuration: Double = 4.0

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 12)

            Button(action: undoAction) {
                Text("Undo")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.63, green: 0.76, blue: 0.98))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.082, green: 0.085, blue: 0.098).opacity(0.98),
                            Color(red: 0.060, green: 0.063, blue: 0.075).opacity(0.98),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .overlay {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.33, green: 0.41, blue: 0.56).opacity(0.17),
                                Color.white.opacity(0.075),
                                Color.white.opacity(0.03),
                                .clear,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * max(progress, 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 8)
        .onAppear {
            progress = 1
            withAnimation(.linear(duration: progressAnimationDuration)) {
                progress = 0
            }
        }
        .onChange(of: token) {
            progress = 1
            withAnimation(.linear(duration: progressAnimationDuration)) {
                progress = 0
            }
        }
    }
}

// MARK: - Shared Components

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.24))

            TextField(
                "",
                text: $text,
                prompt: Text("Search...")
                    .foregroundStyle(.white.opacity(0.22))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13.5, weight: .regular))
            .foregroundStyle(.white.opacity(0.84))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct HotkeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.58))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
                    .stroke(Color.white.opacity(0.058), lineWidth: 1)
            )
    }
}
