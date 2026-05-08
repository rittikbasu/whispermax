import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct InsertionTargetContext {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let bundleURL: URL?
    let displayName: String?
    let icon: NSImage?
}

private enum InsertionSurfaceKind {
    case browser
    case webRuntime
    case webContent
    case nativeEditable
    case unknown

    var prefersPasteFirst: Bool {
        switch self {
        case .browser, .webRuntime, .webContent:
            return true
        case .nativeEditable, .unknown:
            return false
        }
    }
}

private struct FocusedElementSnapshot {
    let role: String?
    let subrole: String?
    let editable: Bool
    let webContent: Bool
}

private struct PasteDispatchOutcome {
    let dispatched: Bool
    let focusedTextTarget: Bool
}

private struct AccessibilityTreeProbeKey: Hashable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
}

@MainActor
final class TextInsertionService {
    private let browserBundlePrefixes: [String] = [
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
    private let pasteFirstBundlePrefixes: [String] = [
        "com.openai.codex",
    ]
    private let webRuntimeFrameworkNames = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
        "QtWebEngineCore.framework",
    ]
    private var accessibilityTreeEnabledTargets = Set<AccessibilityTreeProbeKey>()
    private var accessibilityTreeUnsupportedTargets = Set<AccessibilityTreeProbeKey>()

    func captureTargetContext() -> InsertionTargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return InsertionTargetContext(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            bundleURL: app.bundleURL,
            displayName: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent,
            icon: app.icon
        )
    }

    func insert(_ text: String, target: InsertionTargetContext? = nil) async -> InsertionMethod {
        let resolvedTarget = target ?? captureTargetContext()
        let browserTarget = isBrowserTarget(resolvedTarget)
        let webRuntimeTarget = isWebRuntimeTarget(resolvedTarget)
        let targetPrepared = await prepareTargetForInsertion(
            resolvedTarget,
            prefersWebFocusRestore: browserTarget || webRuntimeTarget
        )
        var focusSnapshot = targetPrepared ? captureFocusedElementSnapshot() : nil
        if targetPrepared,
           webRuntimeTarget,
           !focusSnapshotLooksLikeTextInsertionTarget(focusSnapshot) {
            if await enableExpandedAccessibilityTreeIfAvailable(for: resolvedTarget) {
                focusSnapshot = captureFocusedElementSnapshot()
            }
        }
        let surface = surfaceKind(
            browserTarget: browserTarget,
            webRuntimeTarget: webRuntimeTarget,
            snapshot: focusSnapshot
        )

        if shouldTryAccessibility(for: resolvedTarget, surface: surface) {
            if await tryInsertViaAccessibility(text) {
                return .accessibility
            }
        }

        let pasteOutcome = await pasteViaClipboard(
            text,
            targetPrepared: targetPrepared,
            referenceSnapshot: focusSnapshot,
            settleDelayMilliseconds: surface.prefersPasteFirst ? 130 : 90
        )

        if pasteOutcome.dispatched {
            return pasteOutcome.focusedTextTarget ? .clipboard : .copied
        }

        return .copied
    }

    private func tryInsertViaAccessibility(
        _ text: String
    ) async -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options) else {
            return false
        }

        guard let focusedElement = focusedElement() else {
            return false
        }

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

    private func shouldTryAccessibility(
        for target: InsertionTargetContext?,
        surface: InsertionSurfaceKind
    ) -> Bool {
        if let bundleIdentifier = target?.bundleIdentifier,
           prefersPasteFirst(for: bundleIdentifier) {
            return false
        }

        return surface == .nativeEditable || surface == .unknown
    }

    private func pasteViaClipboard(
        _ text: String,
        targetPrepared: Bool,
        referenceSnapshot: FocusedElementSnapshot?,
        settleDelayMilliseconds: UInt64 = 90
    ) async -> PasteDispatchOutcome {
        copyToClipboard(text)
        let focusedTextTarget = focusSnapshotLooksLikeTextInsertionTarget(referenceSnapshot)

        guard targetPrepared else {
            return PasteDispatchOutcome(dispatched: false, focusedTextTarget: false)
        }

        try? await Task.sleep(for: .milliseconds(settleDelayMilliseconds))

        guard sendCommandV() else {
            return PasteDispatchOutcome(dispatched: false, focusedTextTarget: false)
        }

        return PasteDispatchOutcome(dispatched: true, focusedTextTarget: focusedTextTarget)
    }

    private func focusSnapshotLooksLikeTextInsertionTarget(_ snapshot: FocusedElementSnapshot?) -> Bool {
        guard let snapshot else {
            return false
        }

        if snapshot.editable {
            return true
        }

        if explicitTextInputRole(snapshot.role) {
            return true
        }

        if snapshot.webContent,
           explicitTextInputRole(snapshot.subrole) {
            return true
        }

        return false
    }

    private func explicitTextInputRole(_ role: String?) -> Bool {
        guard let role else {
            return false
        }

        return [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
        ].contains(role)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func prepareTargetForInsertion(
        _ target: InsertionTargetContext?,
        prefersWebFocusRestore: Bool = false
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
        try? await Task.sleep(for: .milliseconds(prefersWebFocusRestore ? 140 : 90))
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func enableExpandedAccessibilityTreeIfAvailable(
        for target: InsertionTargetContext?
    ) async -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        guard let target,
              let bundleIdentifier = target.bundleIdentifier else {
            return false
        }

        let key = AccessibilityTreeProbeKey(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: target.processIdentifier
        )

        guard !accessibilityTreeUnsupportedTargets.contains(key) else {
            return false
        }

        if accessibilityTreeEnabledTargets.contains(key) {
            return true
        }

        // Electron and Chromium apps often hide their real focused editor until this flag is set.
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        let result = AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        guard result == .success else {
            accessibilityTreeUnsupportedTargets.insert(key)
            return false
        }

        accessibilityTreeEnabledTargets.insert(key)
        try? await Task.sleep(for: .milliseconds(100))
        return true
    }

    private func surfaceKind(
        browserTarget: Bool,
        webRuntimeTarget: Bool,
        snapshot: FocusedElementSnapshot?
    ) -> InsertionSurfaceKind {
        if browserTarget {
            return .browser
        }

        if webRuntimeTarget {
            return .webRuntime
        }

        if snapshot?.webContent == true {
            return .webContent
        }

        if snapshot?.editable == true {
            return .nativeEditable
        }

        return .unknown
    }

    private func captureFocusedElementSnapshot() -> FocusedElementSnapshot? {
        guard let focusedElement = focusedElement() else {
            return nil
        }

        let role = stringValue(for: kAXRoleAttribute as CFString, on: focusedElement)
        let subrole = stringValue(for: kAXSubroleAttribute as CFString, on: focusedElement)
        let webContent = focusedElementAppearsWebContent(focusedElement)
        let editable = webContent
            ? focusedElementAppearsEditableWebContent(focusedElement)
            : (
                isAttributeSettable(kAXSelectedTextAttribute as CFString, on: focusedElement)
                    || isAttributeSettable(kAXValueAttribute as CFString, on: focusedElement)
                    || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: focusedElement)
                    || explicitTextInputRole(role)
                    || explicitTextInputRole(subrole)
            )

        return FocusedElementSnapshot(
            role: role,
            subrole: subrole,
            editable: editable,
            webContent: webContent
        )
    }

    private func prefersPasteFirst(for bundleIdentifier: String) -> Bool {
        browserBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
            || pasteFirstBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private func isBrowserTarget(_ target: InsertionTargetContext?) -> Bool {
        guard let bundleIdentifier = target?.bundleIdentifier else {
            return false
        }

        return browserBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private func isWebRuntimeTarget(_ target: InsertionTargetContext?) -> Bool {
        guard let bundleURL = target?.bundleURL else {
            return false
        }

        let frameworksURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)

        for frameworkName in webRuntimeFrameworkNames {
            let frameworkURL = frameworksURL.appendingPathComponent(frameworkName, isDirectory: true)
            if FileManager.default.fileExists(atPath: frameworkURL.path) {
                return true
            }
        }

        return false
    }

    private func focusedElementAppearsEditableWebContent(_ focusedElement: AXUIElement) -> Bool {
        var currentElement: AXUIElement? = focusedElement
        var inspectedDepth = 0

        while let element = currentElement, inspectedDepth < 6 {
            let role = stringValue(for: kAXRoleAttribute as CFString, on: element)
            let subrole = stringValue(for: kAXSubroleAttribute as CFString, on: element)

            if explicitTextInputRole(role) || explicitTextInputRole(subrole) {
                return true
            }

            if role != "AXWebArea" && (
                isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element)
                    || isAttributeSettable(kAXValueAttribute as CFString, on: element)
                    || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element)
            ) {
                return true
            }

            if role == "AXWebArea" {
                return false
            }

            currentElement = axElementValue(for: kAXParentAttribute as CFString, on: element)
            inspectedDepth += 1
        }

        return false
    }

    private func focusedElementAppearsWebContent(_ focusedElement: AXUIElement) -> Bool {
        var currentElement: AXUIElement? = focusedElement
        var inspectedDepth = 0

        while let element = currentElement, inspectedDepth < 6 {
            if let role = stringValue(for: kAXRoleAttribute as CFString, on: element),
               role == "AXWebArea" {
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

    private func stringValue(for attribute: CFString, on element: AXUIElement, maxLength: Int? = nil) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        guard let string = value as? String else {
            return nil
        }

        if let maxLength, string.count > maxLength {
            return String(string.prefix(maxLength))
        }

        return string
    }

    private func axElementValue(for attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
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

        [commandDown, keyDown, keyUp, commandUp].forEach { $0.post(tap: .cghidEventTap) }

        return true
    }
}
