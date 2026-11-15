import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Tracks the Accessibility permission. Polling only runs while onboarding is on screen,
/// so there is zero cost at rest.
@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()
    @Published private(set) var screenRecordingGranted: Bool = CGPreflightScreenCaptureAccess()
    var onGranted: (() -> Void)?
    private var timer: Timer?

    @discardableResult
    func refresh() -> Bool {
        let sr = CGPreflightScreenCaptureAccess()
        if sr != screenRecordingGranted { screenRecordingGranted = sr }
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            if granted { onGranted?() }
        }
        return granted
    }

    /// Triggers the system prompt (which adds the app to the Accessibility list).
    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Newer macOS only lists an app after it actually attempts a capture, so do both.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
    }

    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
