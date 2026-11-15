import AppKit
import ApplicationServices

/// Maintains most-recently-used window order, event-driven (no polling):
///  - NSWorkspace activation notifications catch app switches,
///  - per-app AXObservers catch window focus changes inside an app and window lifecycle.
@MainActor
final class MRUTracker {
    private(set) var order: [CGWindowID] = []
    /// Fired (un-debounced) when the window set probably changed.
    var onChange: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let notifications: [String] = [
        kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observe(app); self?.onChange?() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observers[app.processIdentifier] = nil; self?.onChange?() }
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
        for app in NSWorkspace.shared.runningApplications { observe(app) }
        if let front = NSWorkspace.shared.frontmostApplication { appActivated(front) }
    }

    // MARK: Ordering

    // While Focal itself is switching, the target app transiently reports its *previous* window
    // as focused. Ignore those reports and then pin the window we actually asked for.
    private var ignoreUntil = Date.distantPast
    private var switchToken = 0
    var isSwitching: Bool { Date() < ignoreUntil }

    func beginSwitch(to id: CGWindowID) {
        touch(id)
        ignoreUntil = Date().addingTimeInterval(0.4)
        switchToken += 1
        let token = switchToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.switchToken == token else { return }
                self.touch(id)
                self.onChange?()
            }
        }
    }

    func touch(_ id: CGWindowID) {
        if order.first == id { return }
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    func prune(live: Set<CGWindowID>) {
        order.removeAll { !live.contains($0) }
    }

    /// Tracked windows first (by recency), then the rest by on-screen z-order.
    func sort(_ windows: [WindowInfo]) -> [WindowInfo] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return windows.sorted {
            switch (rank[$0.id], rank[$1.id]) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.zIndex < $1.zIndex
            }
        }
    }

    // MARK: Observation

    private func appActivated(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != ownPID else { return }
        observe(app)
        if isSwitching { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        if let w: AXUIElement = AX.value(el, kAXFocusedWindowAttribute), let id = AX.windowID(w) {
            touch(id)
        }
        onChange?()
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != ownPID, observers[pid] == nil else { return }

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in notifications { AXObserverAddNotification(obs, appEl, n as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
    }

    fileprivate func handle(element: AXUIElement, notification: String) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            if isSwitching { break }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier, let id = AX.windowID(element) { touch(id) }
        default: break
        }
        onChange?()
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let tracker = Unmanaged<MRUTracker>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { tracker.handle(element: element, notification: notification as String) }
}
