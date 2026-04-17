import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct InsertionTargetContext {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let bundleURL: URL?
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

private enum InsertionStrategy {
    case accessibilityFirst
    case pasteFirst
}

private struct FocusedElementSnapshot {
    let role: String?
    let subrole: String?
    let value: String?
    let selectedText: String?
    let selectedRange: CFRange?
    let editable: Bool
    let webContent: Bool
}

private struct PasteDispatchOutcome {
    let dispatched: Bool
    let confirmed: Bool
}

private struct AccessibilityInsertOutcome {
    let applied: Bool
    let confirmed: Bool
}

@MainActor
final class TextInsertionService {
    private let pasteFirstBundlePrefixes: [String] = [
        "com.apple.Safari",
        "company.thebrowser.",
        "com.google.Chrome",
        "com.openai.codex",
        "org.chromium.",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.",
        "com.vivaldi.",
    ]
    private let webRuntimeFrameworkNames = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
        "QtWebEngineCore.framework",
    ]
    private let insertionPolicyStore = InsertionPolicyStore()
    private var learnedStrategies: [String: LearnedInsertionStrategy]

    init() {
        learnedStrategies = insertionPolicyStore.load()
    }

    func captureTargetContext() -> InsertionTargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return InsertionTargetContext(
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            bundleURL: app.bundleURL
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
        let focusSnapshot = targetPrepared ? captureFocusedElementSnapshot() : nil
        let surface = surfaceKind(
            target: resolvedTarget,
            browserTarget: browserTarget,
            webRuntimeTarget: webRuntimeTarget,
            snapshot: focusSnapshot
        )
        let preferredStrategy = preferredStrategy(for: resolvedTarget, surface: surface)

        switch preferredStrategy {
        case .pasteFirst:
            return await insertViaPastePreferredPath(
                text,
                target: resolvedTarget,
                targetPrepared: targetPrepared,
                surface: surface,
                referenceSnapshot: focusSnapshot
            )
        case .accessibilityFirst:
            return await insertViaAccessibilityPreferredPath(
                text,
                target: resolvedTarget,
                targetPrepared: targetPrepared,
                surface: surface,
                referenceSnapshot: focusSnapshot
            )
        }
    }

    private func insertViaPastePreferredPath(
        _ text: String,
        target: InsertionTargetContext?,
        targetPrepared: Bool,
        surface: InsertionSurfaceKind,
        referenceSnapshot: FocusedElementSnapshot?
    ) async -> InsertionMethod {
        let pasteOutcome = await pasteViaClipboard(
            text,
            targetPrepared: targetPrepared,
            referenceSnapshot: referenceSnapshot,
            settleDelayMilliseconds: surface.prefersPasteFirst ? 130 : 90
        )

        if pasteOutcome.dispatched {
            learn(.pasteFirst, for: target, surface: surface, confirmed: pasteOutcome.confirmed)
            let likelyPasteTarget = targetPrepared
                ? likelyPasteTargetExists(for: target, referenceSnapshot: referenceSnapshot)
                : false
            return pasteOutcome.confirmed || likelyPasteTarget ? .clipboard : .copied
        }

        copyToClipboard(text)
        return .copied
    }

    private func insertViaAccessibilityPreferredPath(
        _ text: String,
        target: InsertionTargetContext?,
        targetPrepared: Bool,
        surface: InsertionSurfaceKind,
        referenceSnapshot: FocusedElementSnapshot?
    ) async -> InsertionMethod {
        if shouldTryAccessibility(for: target, surface: surface) {
            let accessibilityOutcome = await tryInsertViaAccessibility(text, referenceSnapshot: referenceSnapshot)
            if accessibilityOutcome.applied {
                learn(.accessibilityFirst, for: target, surface: surface, confirmed: accessibilityOutcome.confirmed)
                return .accessibility
            }
        }

        guard referenceSnapshot?.editable == true else {
            copyToClipboard(text)
            return .copied
        }

        let pasteOutcome = await pasteViaClipboard(
            text,
            targetPrepared: targetPrepared,
            referenceSnapshot: referenceSnapshot,
            settleDelayMilliseconds: 90
        )

        if pasteOutcome.dispatched {
            learn(.pasteFirst, for: target, surface: surface, confirmed: pasteOutcome.confirmed)
            let likelyPasteTarget = targetPrepared
                ? likelyPasteTargetExists(for: target, referenceSnapshot: referenceSnapshot)
                : false
            return pasteOutcome.confirmed || likelyPasteTarget ? .clipboard : .copied
        }

        copyToClipboard(text)
        return .copied
    }

    private func preferredStrategy(
        for target: InsertionTargetContext?,
        surface: InsertionSurfaceKind
    ) -> InsertionStrategy {
        if let bundleIdentifier = target?.bundleIdentifier,
           let learned = learnedStrategies[bundleIdentifier] {
            switch learned {
            case .pasteFirst:
                return .pasteFirst
            case .accessibilityFirst:
                if surface.prefersPasteFirst {
                    return .pasteFirst
                }

                return .accessibilityFirst
            }
        }

        return surface.prefersPasteFirst ? .pasteFirst : .accessibilityFirst
    }

    private func learn(
        _ strategy: LearnedInsertionStrategy,
        for target: InsertionTargetContext?,
        surface: InsertionSurfaceKind,
        confirmed: Bool
    ) {
        guard confirmed, let bundleIdentifier = target?.bundleIdentifier else {
            return
        }

        if learnedStrategies[bundleIdentifier] == strategy {
            return
        }

        learnedStrategies[bundleIdentifier] = strategy
        insertionPolicyStore.save(learnedStrategies)
    }

    private func tryInsertViaAccessibility(
        _ text: String,
        referenceSnapshot: FocusedElementSnapshot?
    ) async -> AccessibilityInsertOutcome {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options) else {
            return AccessibilityInsertOutcome(applied: false, confirmed: false)
        }

        guard let focusedElement = focusedElement() else {
            return AccessibilityInsertOutcome(applied: false, confirmed: false)
        }

        var selectedTextSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        ) == .success,
              selectedTextSettable.boolValue else {
            return AccessibilityInsertOutcome(applied: false, confirmed: false)
        }

        let applied = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success

        let confirmed = applied
            ? await verifyInsertionApplied(
                expectedText: text,
                referenceSnapshot: referenceSnapshot,
                confirmationWindowMilliseconds: 220
            )
            : false

        return AccessibilityInsertOutcome(applied: applied, confirmed: confirmed)
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
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard targetPrepared else {
            restorePasteboard(snapshot, to: pasteboard)
            return PasteDispatchOutcome(dispatched: false, confirmed: false)
        }

        try? await Task.sleep(for: .milliseconds(settleDelayMilliseconds))

        guard sendCommandV() else {
            restorePasteboard(snapshot, to: pasteboard)
            return PasteDispatchOutcome(dispatched: false, confirmed: false)
        }

        let confirmed = await verifyInsertionApplied(
            expectedText: text,
            referenceSnapshot: referenceSnapshot,
            confirmationWindowMilliseconds: 280
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.restorePasteboard(snapshot, to: pasteboard)
        }

        return PasteDispatchOutcome(dispatched: true, confirmed: confirmed)
    }

    private func verifyInsertionApplied(
        expectedText: String,
        referenceSnapshot: FocusedElementSnapshot?,
        confirmationWindowMilliseconds: UInt64
    ) async -> Bool {
        let pollingStep: UInt64 = 55
        let attempts = max(1, Int(confirmationWindowMilliseconds / pollingStep))

        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(pollingStep))
            }

            guard let currentSnapshot = captureFocusedElementSnapshot() else {
                continue
            }

            if insertionAppearsApplied(
                before: referenceSnapshot,
                after: currentSnapshot,
                expectedText: expectedText
            ) {
                return true
            }
        }

        return false
    }

    private func insertionAppearsApplied(
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot,
        expectedText: String
    ) -> Bool {
        if containsInsertedText(after.selectedText, expectedText: expectedText) {
            return true
        }

        if let afterValue = after.value {
            if containsInsertedText(afterValue, expectedText: expectedText) {
                if let beforeValue = before?.value {
                    return beforeValue != afterValue || !containsInsertedText(beforeValue, expectedText: expectedText)
                }

                return true
            }
        }

        if let beforeValue = before?.value,
           let afterValue = after.value,
           beforeValue != afterValue,
           after.editable {
            return true
        }

        if let beforeSelectedText = before?.selectedText,
           let afterSelectedText = after.selectedText,
           beforeSelectedText != afterSelectedText,
           after.editable {
            return true
        }

        if let beforeRange = before?.selectedRange,
           let afterRange = after.selectedRange,
           after.editable,
           (beforeRange.location != afterRange.location || beforeRange.length != afterRange.length) {
            return true
        }

        return false
    }

    private func containsInsertedText(_ haystack: String?, expectedText: String) -> Bool {
        guard let haystack, !expectedText.isEmpty else {
            return false
        }

        return haystack.localizedCaseInsensitiveContains(expectedText)
    }

    private func likelyPasteTargetExists(
        for target: InsertionTargetContext?,
        referenceSnapshot: FocusedElementSnapshot?
    ) -> Bool {
        if focusSnapshotLooksLikeTextInsertionTarget(referenceSnapshot) {
            return true
        }

        guard let target else {
            return false
        }

        return targetMenuAdvertisesPasteEnabled(processIdentifier: target.processIdentifier)
    }

    private func focusSnapshotLooksLikeTextInsertionTarget(_ snapshot: FocusedElementSnapshot?) -> Bool {
        guard let snapshot else {
            return false
        }

        if snapshot.editable {
            return true
        }

        if let selectedRange = snapshot.selectedRange,
           selectedRange.location != kCFNotFound {
            return true
        }

        if let selectedText = snapshot.selectedText,
           !selectedText.isEmpty {
            return true
        }

        return false
    }

    private func targetMenuAdvertisesPasteEnabled(processIdentifier: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let menuBar = axElementValue(
            for: kAXMenuBarAttribute as CFString,
            on: application
        ) else {
            return false
        }

        return menuTreeContainsEnabledPaste(menuBar, depthRemaining: 8)
    }

    private func menuTreeContainsEnabledPaste(_ element: AXUIElement, depthRemaining: Int) -> Bool {
        guard depthRemaining >= 0 else {
            return false
        }

        if let commandChar = stringValue(for: kAXMenuItemCmdCharAttribute as CFString, on: element),
           commandChar.lowercased() == "v",
           let commandModifiers = numberValue(for: kAXMenuItemCmdModifiersAttribute as CFString, on: element),
           commandModifiers == 0,
           let enabled = boolValue(for: kAXEnabledAttribute as CFString, on: element),
           enabled {
            return true
        }

        if let menu = axElementValue(for: "AXMenu" as CFString, on: element),
           menuTreeContainsEnabledPaste(menu, depthRemaining: depthRemaining - 1) {
            return true
        }

        for child in axChildren(of: element) {
            if menuTreeContainsEnabledPaste(child, depthRemaining: depthRemaining - 1) {
                return true
            }
        }

        for visibleChild in axElementsValue(for: kAXVisibleChildrenAttribute as CFString, on: element) {
            if menuTreeContainsEnabledPaste(visibleChild, depthRemaining: depthRemaining - 1) {
                return true
            }
        }

        return false
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

    private func surfaceKind(
        target: InsertionTargetContext?,
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

        let editable = isAttributeSettable(kAXSelectedTextAttribute as CFString, on: focusedElement)
            || isAttributeSettable(kAXValueAttribute as CFString, on: focusedElement)
            || isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: focusedElement)
            || focusedElementHasEditableRole(focusedElement)

        let webContent = focusedElementAppearsWebContent(focusedElement)

        return FocusedElementSnapshot(
            role: stringValue(for: kAXRoleAttribute as CFString, on: focusedElement),
            subrole: stringValue(for: kAXSubroleAttribute as CFString, on: focusedElement),
            value: stringValue(for: kAXValueAttribute as CFString, on: focusedElement, maxLength: 4096),
            selectedText: stringValue(for: kAXSelectedTextAttribute as CFString, on: focusedElement, maxLength: 1024),
            selectedRange: selectedTextRange(on: focusedElement),
            editable: editable,
            webContent: webContent
        )
    }

    private func focusedElementHasEditableRole(_ focusedElement: AXUIElement) -> Bool {
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

    private func prefersPasteFirst(for bundleIdentifier: String) -> Bool {
        pasteFirstBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private func isBrowserTarget(_ target: InsertionTargetContext?) -> Bool {
        guard let bundleIdentifier = target?.bundleIdentifier else {
            return false
        }

        return prefersPasteFirst(for: bundleIdentifier)
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

    private func selectedTextRange(on element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
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

    private func numberValue(for attribute: CFString, on element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }

        return nil
    }

    private func boolValue(for attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        return nil
    }

    private func axChildren(of element: AXUIElement) -> [AXUIElement] {
        axElementsValue(for: kAXChildrenAttribute as CFString, on: element)
    }

    private func axElementsValue(for attribute: CFString, on element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let array = value as? [Any] else {
            return []
        }

        return array.compactMap { candidate in
            let candidateRef = candidate as CFTypeRef
            guard CFGetTypeID(candidateRef) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeDowncast(candidateRef, to: AXUIElement.self)
        }
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
