import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updateController = AppUpdateController()
    let controller: AppController

    private var hotkeyMonitor: GlobalHotkeyMonitor?
    private var recorderPanelController: RecorderPanelController?
    private var terminationTask: Task<Void, Never>?

    override init() {
        controller = AppController(updateController: updateController)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        recorderPanelController = RecorderPanelController(controller: controller)
        hotkeyMonitor = GlobalHotkeyMonitor(controller: controller)

        controller.phaseDidChange = { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.recorderPanelController?.update(for: phase)
            }
        }

        controller.onOnboardingComplete = { [weak self] in
            self?.hotkeyMonitor?.start()
        }

        controller.launch()

        if controller.hasCompletedOnboarding {
            hotkeyMonitor?.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions()
        controller.refreshUpdateState()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        hotkeyMonitor?.stop()
        controller.pauseModelDownload()
        controller.cancelRecording()

        guard terminationTask == nil else { return .terminateLater }
        let controller = controller
        terminationTask = Task { @MainActor [weak self] in
            await controller.shutdownTranscriptionEngineAndWait()
            self?.terminationTask = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }
}
