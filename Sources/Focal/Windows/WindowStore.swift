import AppKit

/// Cached, MRU-sorted window list. The switcher reads the cache synchronously (instant open)
/// and a background refresh corrects it a few ms later.
@MainActor
final class WindowStore {
    let engine = WindowDiscoveryEngine()
    let tracker = MRUTracker()
    private(set) var windows: [WindowInfo] = []

    private var refreshing = false
    private var waiters: [([WindowInfo]) -> Void] = []
    private var debounce: DispatchWorkItem?

    func start() {
        tracker.onChange = { [weak self] in self?.scheduleRefresh() }
        tracker.start()
        refresh()
    }

    /// Call right after switching so a fast second switch sees the new order immediately.
    func noteFocused(_ id: CGWindowID) {
        tracker.beginSwitch(to: id)
        windows = tracker.sort(windows)
    }

    func scheduleRefresh() {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func refresh(completion: (([WindowInfo]) -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        guard !refreshing else { return }
        refreshing = true
        engine.enumerate { [weak self] snap in
            guard let self else { return }
            let raw = snap.windows
            self.tracker.prune(live: Set(raw.map(\.id)))
            // The window that is really focused right now is by definition most recent.
            if !self.tracker.isSwitching, let f = snap.focused, raw.contains(where: { $0.id == f }) { self.tracker.touch(f) }
            self.windows = self.tracker.sort(raw)
            self.refreshing = false
            let ws = self.waiters; self.waiters = []
            ws.forEach { $0(self.windows) }
        }
    }
}

enum WindowFocuser {
    /// Brings a window to front, un-minimizing / un-hiding as needed.
    static func focus(_ w: WindowInfo) {
        if let app = NSRunningApplication(processIdentifier: w.pid), app.isHidden { app.unhide() }
        let appEl = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        if w.isMinimized {
            AXUIElementSetAttributeValue(w.axWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.axWindow, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, w.axWindow)
    }
}
