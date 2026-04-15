import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    private var hotkeyMonitor: GlobalHotkeyMonitor?
    private var recorderPanelController: RecorderPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        recorderPanelController = RecorderPanelController(controller: controller)
        hotkeyMonitor = GlobalHotkeyMonitor(controller: controller)
        hotkeyMonitor?.start()

        controller.phaseDidChange = { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.recorderPanelController?.update(for: phase)
            }
        }

        controller.launch()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
    }
}
