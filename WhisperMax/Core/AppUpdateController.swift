import Foundation
import Sparkle

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
final class AppUpdateController: NSObject {
    private let standardUpdaterController: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    var onStateChange: (() -> Void)?

    override init() {
        standardUpdaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        observeUpdaterState()
    }

    var canCheckForUpdates: Bool {
        standardUpdaterController.updater.canCheckForUpdates
    }

    var automaticallyChecksForUpdates: Bool {
        standardUpdaterController.updater.automaticallyChecksForUpdates
    }

    var selectedCadence: UpdateCheckCadence {
        UpdateCheckCadence(interval: standardUpdaterController.updater.updateCheckInterval)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        standardUpdaterController.updater.automaticallyChecksForUpdates = enabled

        if enabled, standardUpdaterController.updater.updateCheckInterval <= 0 {
            standardUpdaterController.updater.updateCheckInterval = UpdateCheckCadence.everyTwelveHours.interval
        }
    }

    func setCadence(_ cadence: UpdateCheckCadence) {
        standardUpdaterController.updater.updateCheckInterval = cadence.interval
    }

    func checkForUpdates() {
        standardUpdaterController.checkForUpdates(nil)
    }

    private func observeUpdaterState() {
        let updater = standardUpdaterController.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.onStateChange?()
                }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
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
}
