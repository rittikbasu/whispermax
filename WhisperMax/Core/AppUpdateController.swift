import Foundation
import Sparkle

struct AvailableAppUpdate: Equatable {
    let version: String
    let releaseNotesURL: URL?
    let isSimulated: Bool
}

enum UpdateCheckCadence: String, CaseIterable, Codable, Identifiable {
    case everySixHours
    case everyTwelveHours
    case daily

    var id: String { rawValue }

    var interval: TimeInterval {
        switch self {
        case .everySixHours:
            return 60 * 60 * 6
        case .everyTwelveHours:
            return 60 * 60 * 12
        case .daily:
            return 60 * 60 * 24
        }
    }

    var label: String {
        switch self {
        case .everySixHours:
            return "6 hours"
        case .everyTwelveHours:
            return "12 hours"
        case .daily:
            return "daily"
        }
    }

    init(interval: TimeInterval) {
        let sixHours = UpdateCheckCadence.everySixHours.interval
        let twelveHours = UpdateCheckCadence.everyTwelveHours.interval
        let oneDay = UpdateCheckCadence.daily.interval

        switch interval {
        case ..<((sixHours + twelveHours) / 2):
            self = .everySixHours
        case ..<((twelveHours + oneDay) / 2):
            self = .everyTwelveHours
        default:
            self = .daily
        }
    }
}

@MainActor
final class AppUpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private static let defaultCadence: UpdateCheckCadence = .everySixHours

#if DEBUG
    private enum TestingKey {
        static let simulatedAvailableVersion = "SimulatedAvailableUpdateVersion"
        static let simulatedAvailableReleaseNotesURL = "SimulatedAvailableReleaseNotesURL"
        static let updateCheckIntervalOverride = "UpdateCheckIntervalOverrideSeconds"
    }
#endif

    private var standardUpdaterController: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var discoveredUpdate: AvailableAppUpdate?
#if DEBUG
    private var simulatedUpdate: AvailableAppUpdate?
#endif

    var onStateChange: (() -> Void)?

    override init() {
        super.init()
        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        observeUpdaterState()
        refreshState()
    }

    var canCheckForUpdates: Bool {
        standardUpdaterController.updater.canCheckForUpdates
    }

    var availableUpdate: AvailableAppUpdate? {
#if DEBUG
        simulatedUpdate ?? discoveredUpdate
#else
        discoveredUpdate
#endif
    }

    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func checkForUpdates() {
        standardUpdaterController.checkForUpdates(nil)
    }

    func refreshState() {
#if DEBUG
        syncTestingOverrides()
        applyTestingIntervalOverride()
#endif
        applyDefaultUpdateCheckSettings()
        onStateChange?()
    }

    private func observeUpdaterState() {
        let updater = standardUpdaterController.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.onStateChange?()
                }
            },
            updater.observe(\.updateCheckInterval, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.onStateChange?()
                }
            },
        ]
    }

    private func applyDefaultUpdateCheckSettings() {
        let updater = standardUpdaterController.updater

        if !updater.automaticallyChecksForUpdates {
            updater.automaticallyChecksForUpdates = true
        }

        if updater.updateCheckInterval <= 0 {
            updater.updateCheckInterval = Self.defaultCadence.interval
        }
    }

#if DEBUG
    private func applyTestingIntervalOverride() {
        guard let overrideInterval = testingIntervalOverride else {
            return
        }

        let updater = standardUpdaterController.updater
        if updater.updateCheckInterval != overrideInterval {
            updater.updateCheckInterval = overrideInterval
        }
    }

    private var testingIntervalOverride: TimeInterval? {
        let defaults = UserDefaults.standard
        let overrideSeconds = defaults.double(forKey: TestingKey.updateCheckIntervalOverride)
        guard overrideSeconds > 0 else {
            return nil
        }
        return overrideSeconds
    }

    private func syncTestingOverrides() {
        let defaults = UserDefaults.standard
        let trimmedVersion = defaults.string(forKey: TestingKey.simulatedAvailableVersion)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let trimmedVersion, !trimmedVersion.isEmpty else {
            simulatedUpdate = nil
            return
        }

        let storedReleaseNotesString = defaults.string(forKey: TestingKey.simulatedAvailableReleaseNotesURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let releaseNotesURL =
            storedReleaseNotesString.flatMap { URL(string: $0) }
            ?? defaults.url(forKey: TestingKey.simulatedAvailableReleaseNotesURL)
            ?? URL(string: "https://github.com/rittikbasu/whispermax/releases")

        simulatedUpdate = AvailableAppUpdate(
            version: trimmedVersion,
            releaseNotesURL: releaseNotesURL,
            isSimulated: true
        )
    }
#endif

    private func makeAvailableUpdate(from item: SUAppcastItem) -> AvailableAppUpdate {
        let version = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
        return AvailableAppUpdate(
            version: version,
            releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL ?? item.infoURL,
            isSimulated: false
        )
    }

    private func clearDiscoveredUpdate(matching item: SUAppcastItem? = nil) {
        guard let existingUpdate = discoveredUpdate else {
            return
        }

        guard let item else {
            discoveredUpdate = nil
            return
        }

        let version = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
        if existingUpdate.version == version {
            discoveredUpdate = nil
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        discoveredUpdate = makeAvailableUpdate(from: item)
        onStateChange?()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        discoveredUpdate = nil
        onStateChange?()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip {
            clearDiscoveredUpdate(matching: updateItem)
            onStateChange?()
        }
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        discoveredUpdate = makeAvailableUpdate(from: update)
        onStateChange?()
    }
}
