import AppKit
import SwiftUI

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            configureWindowIfNeeded(for: view)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowIfNeeded(for: nsView)
        }
    }

    private func configureWindowIfNeeded(for view: NSView) {
        guard let window = view.window else {
            return
        }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.isOpaque = false
        window.backgroundColor = .clear

        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }

        positionTrafficLights(in: window)
    }

    private func positionTrafficLights(in window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton),
            let container = closeButton.superview
        else {
            return
        }

        let buttons = [closeButton, minimizeButton, zoomButton]
        let topInset: CGFloat = 14
        let spacing: CGFloat = 20
        let sidebarWidth: CGFloat = 80
        let buttonSize = closeButton.frame.width
        let groupWidth = buttonSize + CGFloat(buttons.count - 1) * spacing
        let leadingInset = floor((sidebarWidth - groupWidth) / 2)
        let buttonY = max(0, container.bounds.height - closeButton.frame.height - topInset)

        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(
                NSPoint(
                    x: leadingInset + (CGFloat(index) * spacing),
                    y: buttonY
                )
            )
        }
    }
}
