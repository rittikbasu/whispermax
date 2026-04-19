import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class RecorderPanelController {
    private let panel: NSPanel
    private let panelHeight: CGFloat = 112
    private let minPanelWidth: CGFloat = 440
    private let maxPanelWidth: CGFloat = 520

    init(controller: AppController) {
        let rootView = RecorderPanelView()
            .environment(controller)
            .preferredColorScheme(.dark)

        let hostingController = NSHostingController(rootView: rootView)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxPanelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }

    func update(for phase: RecordingPhase) {
        switch phase {
        case .recording, .transcribing, .inserted, .error:
            show()
        case .ready, .loadingModel:
            hide()
        }
    }

    private func show() {
        if !panel.isVisible {
            positionPanel()
            panel.orderFrontRegardless()
        }
    }

    private func hide() {
        panel.orderOut(nil)
    }

    private func positionPanel() {
        let frontmostWindowFrame = frontmostWindowFrame()
        let anchorPoint = frontmostWindowFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(anchorPoint, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = targetScreen?.visibleFrame else { return }

        let widthBase = frontmostWindowFrame.map { $0.width * 0.58 } ?? (frame.width - 420)
        let width = max(minPanelWidth, min(maxPanelWidth, widthBase))
        let anchorMidX = frontmostWindowFrame?.midX ?? frame.midX
        let originX = min(max(anchorMidX - width / 2, frame.minX + 26), frame.maxX - width - 26)
        let origin = NSPoint(
            x: originX,
            y: frame.maxY - panelHeight - 28
        )

        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: panelHeight)), display: false)
    }

    private func frontmostWindowFrame() -> CGRect? {
        guard let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1

            guard ownerPID == processIdentifier, layer == 0, alpha > 0 else {
                continue
            }

            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 240,
                  bounds.height > 160 else {
                continue
            }

            return bounds
        }

        return nil
    }
}
