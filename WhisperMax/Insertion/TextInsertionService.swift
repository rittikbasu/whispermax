import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct InsertionTargetContext {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
}

@MainActor
final class TextInsertionService {
    private let clipboardPreferredBundlePrefixes: [String] = [
        "com.apple.Safari",
        "company.thebrowser.",
        "com.google.Chrome",
        "org.chromium.",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.",
        "com.vivaldi.",
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

    func insert(_ text: String, target: InsertionTargetContext? = nil) async -> InsertionMethod {
        let resolvedTarget = target ?? captureTargetContext()
        let browserTarget = isBrowserTarget(resolvedTarget)
        let targetPrepared = await prepareTargetForInsertion(
            resolvedTarget,
            prefersBrowserFocusRestore: browserTarget
        )
        let editableFocus = targetPrepared ? hasLikelyEditableFocus() : false

        if browserTarget {
            if await pasteViaClipboard(
                text,
                targetPrepared: targetPrepared,
                settleDelayMilliseconds: 120
            ) {
                return editableFocus ? .clipboard : .copied
            }

            copyToClipboard(text)
            return .copied
        }

        if shouldTryAccessibility(for: resolvedTarget), tryInsertViaAccessibility(text) {
            return .accessibility
        }

        guard editableFocus else {
            copyToClipboard(text)
            return .copied
        }

        if await pasteViaClipboard(text, targetPrepared: targetPrepared) {
            return .clipboard
        }

        copyToClipboard(text)
        return .copied
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
        if let bundleIdentifier = target?.bundleIdentifier,
           prefersClipboardFallback(for: bundleIdentifier) {
            return false
        }

        return !focusedElementAppearsWebContent()
    }

    private func pasteViaClipboard(
        _ text: String,
        targetPrepared: Bool,
        settleDelayMilliseconds: UInt64 = 70
    ) async -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard targetPrepared else {
            restorePasteboard(snapshot, to: pasteboard)
            return false
        }

        try? await Task.sleep(for: .milliseconds(settleDelayMilliseconds))

        guard sendCommandV() else {
            restorePasteboard(snapshot, to: pasteboard)
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.restorePasteboard(snapshot, to: pasteboard)
        }

        return true
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private func prepareTargetForInsertion(
        _ target: InsertionTargetContext?,
        prefersBrowserFocusRestore: Bool = false
    ) async -> Bool {
        guard let target else {
            return true
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
            return true
        }

        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier) else {
            return false
        }

        _ = app.activate()
        try? await Task.sleep(for: .milliseconds(prefersBrowserFocusRestore ? 140 : 90))
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func hasLikelyEditableFocus() -> Bool {
        guard let focusedElement = focusedElement() else {
            return false
        }

        if isAttributeSettable(kAXSelectedTextAttribute as CFString, on: focusedElement)
            || isAttributeSettable(kAXValueAttribute as CFString, on: focusedElement)
            || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: focusedElement) {
            return true
        }

        guard let role = stringValue(for: kAXRoleAttribute as CFString, on: focusedElement) else {
            return false
        }

        return [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
        ].contains(role)
    }

    private func prefersClipboardFallback(for bundleIdentifier: String) -> Bool {
        clipboardPreferredBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private func isBrowserTarget(_ target: InsertionTargetContext?) -> Bool {
        guard let bundleIdentifier = target?.bundleIdentifier else {
            return false
        }

        return prefersClipboardFallback(for: bundleIdentifier)
    }

    private func focusedElementAppearsWebContent() -> Bool {
        guard let focusedElement = focusedElement() else {
            return false
        }

        var currentElement: AXUIElement? = focusedElement
        var inspectedDepth = 0

        while let element = currentElement, inspectedDepth < 6 {
            if let role = stringValue(for: kAXRoleAttribute as CFString, on: element),
               role == "AXWebArea" || role == kAXGroupRole as String {
                return true
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentValue) == .success,
                  let parentValue else {
                return false
            }

            currentElement = unsafeDowncast(parentValue, to: AXUIElement.self)
            inspectedDepth += 1
        }

        return false
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
              let focusedElementValue else {
            return nil
        }

        return unsafeDowncast(focusedElementValue, to: AXUIElement.self)
    }

    private func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private func stringValue(for attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func sendCommandV() -> Bool {
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

        events.forEach { $0.post(tap: .cghidEventTap) }

        return true
    }
}
