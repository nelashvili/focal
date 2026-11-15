import AppKit
import ApplicationServices

/// Enumerates user-visible windows. Blocking AX calls happen off the main thread.
///
/// Strategy: AX is the source of truth (it sees minimized + hidden-app windows);
/// CGWindowList supplies cheap front-to-back z-order for the on-screen ones.
final class WindowDiscoveryEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "focal.discovery", qos: .userInteractive)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    struct Snapshot { var windows: [WindowInfo]; var focused: CGWindowID? }

    func enumerate(completion: @escaping @MainActor (Snapshot) -> Void) {
        queue.async {
            let result = Snapshot(windows: self.enumerateSync(), focused: Self.focusedWindowID())
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func enumerateSync() -> [WindowInfo] {
        let zOrder = Self.onScreenZOrder()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }

        let lock = NSLock()
        var all: [WindowInfo] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = Self.windows(of: apps[i], zOrder: zOrder)
            lock.lock(); all.append(contentsOf: found); lock.unlock()
        }
        return all.sorted { $0.zIndex < $1.zIndex }
    }

    private static func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3)
        guard let w: AXUIElement = AX.value(el, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(w)
    }

    private static func windows(of app: NSRunningApplication, zOrder: [CGWindowID: Int]) -> [WindowInfo] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3) // a hung app must not stall the switcher
        guard let axWindows: [AXUIElement] = AX.value(appEl, kAXWindowsAttribute) else { return [] }

        let name = app.localizedName ?? "Unknown"
        return axWindows.compactMap { w in
            guard isSwitchable(w), let id = AX.windowID(w) else { return nil }
            let title: String = AX.value(w, kAXTitleAttribute) ?? ""
            return WindowInfo(
                id: id, pid: app.processIdentifier, appName: name, bundleID: app.bundleIdentifier,
                title: title, icon: app.icon,
                isMinimized: AX.bool(w, kAXMinimizedAttribute), isAppHidden: app.isHidden,
                zIndex: zOrder[id] ?? Int.max, axWindow: w)
        }
    }

    /// Standard windows and dialogs; excludes palettes, popovers, tooltips, etc.
    private static func isSwitchable(_ w: AXUIElement) -> Bool {
        let role: String? = AX.value(w, kAXRoleAttribute)
        guard role == kAXWindowRole as String else { return false }
        let sub: String? = AX.value(w, kAXSubroleAttribute)
        return sub == kAXStandardWindowSubrole as String || sub == kAXDialogSubrole as String
    }

    private static func onScreenZOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var map: [CGWindowID: Int] = [:]
        for (i, d) in list.enumerated() where (d[kCGWindowLayer as String] as? Int) == 0 {
            if let n = d[kCGWindowNumber as String] as? UInt32 { map[n] = i }
        }
        return map
    }
}
