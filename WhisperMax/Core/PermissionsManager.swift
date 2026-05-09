import AVFoundation
import ApplicationServices
import Foundation
import AppKit

enum MicrophonePermissionState: Equatable {
    case notDetermined
    case authorized
    case needsSettings
    case unavailable
}

@MainActor
final class PermissionsManager {
    var isAccessibilityGranted: Bool {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrusted() || AXIsProcessTrustedWithOptions(options)
    }

    var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    var microphonePermissionState: MicrophonePermissionState {
        switch microphoneAuthorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .needsSettings
        @unknown default:
            return .unavailable
        }
    }

    var isMicrophoneGranted: Bool {
        microphonePermissionState == .authorized
    }

    func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func requestMicrophoneAccess() async -> Bool {
        switch microphonePermissionState {
        case .authorized:
            return true
        case .needsSettings, .unavailable:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
