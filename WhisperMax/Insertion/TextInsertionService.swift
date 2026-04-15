import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum TextInsertionError: LocalizedError {
    case clipboardPasteFailed

    var errorDescription: String? {
        switch self {
        case .clipboardPasteFailed:
            return "Unable to paste transcript into the focused app."
        }
    }
}

struct InsertionTargetContext {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

@MainActor
final class TextInsertionService {
    private let forcedClipboardBundleIdentifiers: Set<String> = [
        "com.openai.codex",
    ]

    func captureTargetContext() -> InsertionTargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return InsertionTargetContext(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier
        )
    }

    func insert(_ text: String, target: InsertionTargetContext? = nil) throws -> InsertionMethod {
        let resolvedTarget = target ?? captureTargetContext()

        if shouldTryAccessibility(for: resolvedTarget), tryInsertViaAccessibility(text) {
            return .accessibility
        }

        try pasteViaClipboard(text, target: resolvedTarget)
        return .clipboard
    }

    private func tryInsertViaAccessibility(_ text: String) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options) else {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
              let focusedElementValue else {
            return false
        }

        let focusedElement = focusedElementValue as! AXUIElement
        var selectedTextSettable = DarwinBoolean(false)

        guard AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success,
              selectedTextSettable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private func shouldTryAccessibility(for target: InsertionTargetContext?) -> Bool {
        guard let bundleIdentifier = target?.bundleIdentifier else {
            return true
        }

        return !forcedClipboardBundleIdentifiers.contains(bundleIdentifier)
    }

    private func pasteViaClipboard(_ text: String, target: InsertionTargetContext?) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        let targetProcessIdentifier = target?.processIdentifier

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard sendCommandV(to: targetProcessIdentifier) else {
            restorePasteboard(snapshot, to: pasteboard)
            throw TextInsertionError.clipboardPasteFailed
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.restorePasteboard(snapshot, to: pasteboard)
        }
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else {
            return []
        }

        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private func sendCommandV(to processIdentifier: pid_t?) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Command), keyDown: false) else {
            return false
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []

        let events = [commandDown, keyDown, keyUp, commandUp]

        if let processIdentifier, processIdentifier > 0 {
            events.forEach { $0.postToPid(processIdentifier) }
        } else {
            events.forEach { $0.post(tap: .cghidEventTap) }
        }

        return true
    }
}
