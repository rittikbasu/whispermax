import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotkeyMonitor {
    private weak var controller: AppController?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var localMonitor: Any?

    private let hotKeyIdentifier: UInt32 = 1
    private let hotKeySignature: OSType = 0x574D4158 // WMAX

    init(controller: AppController) {
        self.controller = controller
    }

    func start() {
        stop()
        installHotKeyHandler()
        registerPrimaryHotKey()
        installLocalMonitor()
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                let monitor = Unmanaged<GlobalHotkeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return monitor.handleHotKeyEvent(event)
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyHandler
        )
    }

    private func registerPrimaryHotKey() {
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIdentifier)

        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if matchesLocalFallbackToggle(event) {
                triggerToggle()
                return nil
            }

            if matchesCancel(event) {
                controller?.cancelRecording()
                return nil
            }

            return event
        }
    }

    private func handleHotKeyEvent(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard hotKeyID.signature == hotKeySignature, hotKeyID.id == hotKeyIdentifier else {
            return OSStatus(eventNotHandledErr)
        }

        triggerToggle()
        return noErr
    }

    private func triggerToggle() {
        Task { @MainActor [weak controller] in
            await controller?.toggleRecording()
        }
    }

    private func matchesLocalFallbackToggle(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else {
            return false
        }

        let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        return event.keyCode == 49 && relevantFlags == [.function]
    }

    private func matchesCancel(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        return event.keyCode == 53 && controller.phase == .recording
    }
}
