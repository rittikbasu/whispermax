import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updateController = AppUpdateController()
    let controller: AppController

    private var hotkeyMonitor: GlobalHotkeyMonitor?
    private var recorderPanelController: RecorderPanelController?
    private var terminationTask: Task<Void, Never>?
#if DEBUG
    private var debugLiveCaptureSmoke: DebugLiveCaptureSmoke?
#endif

    override init() {
        controller = AppController(updateController: updateController)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let isRecordingCancellationCheck = arguments.contains("--whispermax-test-recording-cancellation")
        let isPhaseResetCheck = arguments.contains("--whispermax-test-phase-reset")
        let isLiveCaptureControlCheck = arguments.contains("--whispermax-test-live-capture-control")
        if isLiveCaptureControlCheck {
            Task { @MainActor [weak self] in
                guard let self else { exit(EXIT_FAILURE) }
                let passed = await DebugLiveCaptureSmoke.runPrivateControlDirectoryIntegrationCheck(
                    controller: controller
                )
                let result = passed ? "passed" : "failed"
                FileHandle.standardOutput.write(
                    Data("WhisperMax live capture control smoke \(result) (private path and state handshake; no capture)\n".utf8)
                )
                exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            return
        }

        if isRecordingCancellationCheck || isPhaseResetCheck {
            Task { @MainActor [weak self] in
                guard let self else { exit(EXIT_FAILURE) }
                if isRecordingCancellationCheck && !ModelLocator.hasInstalledPhononModel {
                    let modelPath = ModelLocator.phononModelURL.path
                    let message = "WhisperMax recording cancellation smoke requires the installed Phonon-2 Core ML model at \(modelPath). Install the model in WhisperMax, then rerun the harness.\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    exit(EXIT_FAILURE)
                }

                let resetPassed = await controller.runDelayedPhaseResetIntegrationCheck()
                if isPhaseResetCheck {
                    let result = resetPassed ? "passed" : "failed"
                    FileHandle.standardOutput.write(Data("WhisperMax phase reset smoke \(result)\n".utf8))
                    exit(resetPassed ? EXIT_SUCCESS : EXIT_FAILURE)
                }

                let startupPassed = await controller.runRecordingStartCancellationIntegrationCheck()
                let errorPassed = controller.runEarlyRecorderErrorIntegrationCheck()
                let finishPassed = controller.runPendingFinishCancellationIntegrationCheck()
                let tapPassed = controller.runStaleTapBufferIntegrationCheck()
                let passed = resetPassed && startupPassed && errorPassed && finishPassed && tapPassed
                let result = passed ? "passed" : "failed"
                let output = "WhisperMax recording cancellation smoke \(result) (reset=\(resetPassed), start=\(startupPassed), error=\(errorPassed), finish=\(finishPassed), tap=\(tapPassed))\n"
                FileHandle.standardOutput.write(Data(output.utf8))
                exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            return
        }

        let liveCaptureSmokeDirectory = DebugLiveCaptureSmoke.consumeOptInDirectory()
#endif

        recorderPanelController = RecorderPanelController(controller: controller)
#if DEBUG
        if let liveCaptureSmokeDirectory {
            debugLiveCaptureSmoke = DebugLiveCaptureSmoke(directory: liveCaptureSmokeDirectory)
        }
#endif
#if DEBUG
        hotkeyMonitor = debugLiveCaptureSmoke == nil ? GlobalHotkeyMonitor(controller: controller) : nil
#else
        hotkeyMonitor = GlobalHotkeyMonitor(controller: controller)
#endif

        controller.phaseDidChange = { [weak self] phase in
            Task { @MainActor [weak self] in
                self?.recorderPanelController?.update(for: phase)
            }
        }

        controller.onOnboardingComplete = { [weak self] in
            self?.hotkeyMonitor?.start()
        }

        controller.launch()

#if DEBUG
        debugLiveCaptureSmoke?.start(controller: controller)
#endif

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
        controller.cancelRecording()

        guard terminationTask == nil else { return .terminateLater }
        let controller = controller
        terminationTask = Task { @MainActor [weak self] in
            await controller.pauseModelDownload()
            await controller.shutdownTranscriptionEngineAndWait()
            self?.terminationTask = nil
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
#if DEBUG
        debugLiveCaptureSmoke?.stop()
#endif
    }
}
