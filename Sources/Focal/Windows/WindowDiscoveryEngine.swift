import AppKit
import ApplicationServices

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

/// Enumerates user-visible windows. Blocking AX calls happen off the main thread.
///
/// Strategy: AX is the source of truth (it sees minimized + hidden-app windows);
/// CGWindowList supplies cheap front-to-back z-order for the on-screen ones, and also
/// reveals windows that AX's window list leaves out (other Spaces, full-screen windows).
final class WindowDiscoveryEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "focal.discovery", qos: .userInteractive)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    // Guarded by `lock` (touched from concurrentPerform).
    private let lock = NSLock()
    /// Last good result per app, reused when an app is too busy to answer in time.
    private var lastByPID: [pid_t: [WindowInfo]] = [:]
    /// CG windows the remote-token search already failed to resolve (helper/offscreen
    /// surfaces, not real windows), so we don't search for them on every refresh.
    private var unresolvable: [pid_t: Set<CGWindowID>] = [:]
    /// Windows found by the remote-token search, so off-Space windows aren't re-searched each refresh.
    private var remote: [CGWindowID: AXUIElement] = [:]

    struct Snapshot { var windows: [WindowInfo]; var focused: CGWindowID? }

    func enumerate(completion: @escaping @MainActor (Snapshot) -> Void) {
        queue.async {
            let result = Snapshot(windows: self.enumerateSync(), focused: Self.focusedWindowID())
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func enumerateSync() -> [WindowInfo] {
        let cg = Self.cgWindows()
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isTerminated
        }

        var all: [WindowInfo] = []
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let found = self.windows(of: apps[i], cg: cg)
            lock.lock(); all.append(contentsOf: found); lock.unlock()
        }
        let livePIDs = Set(apps.map(\.processIdentifier))
        lock.lock()
        lastByPID = lastByPID.filter { livePIDs.contains($0.key) }
        unresolvable = unresolvable.filter { livePIDs.contains($0.key) }
        let liveIDs = Set(all.map(\.id))
        remote = remote.filter { liveIDs.contains($0.key) }
        lock.unlock()
        return all.sorted { $0.zIndex < $1.zIndex }
    }

    private static func focusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3)
        guard let w: AXUIElement = AX.value(el, kAXFocusedWindowAttribute) else { return nil }
        return AX.windowID(w)
    }

    private func windows(of app: NSRunningApplication, cg: CGInfo) -> [WindowInfo] {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3) // a hung app must not stall the switcher
        let (list, err): ([AXUIElement]?, AXError) = AX.read(appEl, kAXWindowsAttribute)

        if list == nil, err == .cannotComplete {
            // Busy, not windowless: keep showing what it had instead of dropping its windows.
            lock.lock(); defer { lock.unlock() }
            return lastByPID[pid] ?? []
        }

        var elements: [CGWindowID: AXUIElement] = [:]
        for w in list ?? [] {
            if let id = AX.windowID(w), Self.isSwitchable(w) { elements[id] = w }
        }

        // Windows CG knows about but AX's list omitted: usually on another Space.
        lock.lock()
        let skip = unresolvable[pid] ?? []
        let cached = remote
        lock.unlock()
        // Only windows that live on some Space. Inactive native tabs (Terminal, Finder, ...) are
        // separate windows too, but belong to no Space, and must not show up as extra windows.
        var missing = (cg.candidates[pid] ?? []).subtracting(elements.keys).subtracting(skip)
            .filter(Self.isOnSomeSpace)
        for id in missing {
            if let el = cached[id], AX.windowID(el) == id { elements[id] = el; missing.remove(id) }
        }
        if !missing.isEmpty {
            let found = Self.searchWindows(pid: pid, wanted: missing)
            elements.merge(found) { a, _ in a }
            lock.lock()
            remote.merge(found) { _, b in b }
            unresolvable[pid, default: []].formUnion(missing.subtracting(found.keys))
            lock.unlock()
        }

        let name = app.localizedName ?? "Unknown"
        let result = elements.map { id, w in
            let title: String = AX.value(w, kAXTitleAttribute) ?? ""
            return WindowInfo(
                id: id, pid: pid, appName: name, bundleID: app.bundleIdentifier,
                title: title, icon: app.icon,
                isMinimized: AX.bool(w, kAXMinimizedAttribute), isAppHidden: app.isHidden,
                zIndex: cg.zOrder[id] ?? Int.max, axWindow: w)
        }
        lock.lock(); lastByPID[pid] = result; lock.unlock()
        return result
    }

    /// Walks the app's AX element IDs looking for the given windows. Bounded in time,
    /// and stops as soon as everything wanted is found.
    private static func searchWindows(pid: pid_t, wanted: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var found: [CGWindowID: AXUIElement] = [:]
        let deadline = Date().addingTimeInterval(0.15)
        for elementID in UInt64(0)..<1000 {
            if found.count == wanted.count || Date() > deadline { break }
            guard let el = AX.element(pid: pid, elementID: elementID) else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            guard let id = AX.windowID(el), wanted.contains(id), found[id] == nil,
                  isSwitchable(el, strict: true) else { continue }
            found[id] = el
        }
        return found
    }

    /// Standard windows and dialogs; excludes palettes, popovers, tooltips, etc.
    private static func isOnSomeSpace(_ id: CGWindowID) -> Bool {
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [id] as CFArray)?.takeRetainedValue() as? [Any]
        return !(spaces ?? []).isEmpty
    }

    /// `strict` for elements not taken from the window list, which may be any child element.
    private static func isSwitchable(_ w: AXUIElement, strict: Bool = false) -> Bool {
        let (role, roleErr): (String?, AXError) = AX.read(w, kAXRoleAttribute)
        let (sub, subErr): (String?, AXError) = AX.read(w, kAXSubroleAttribute)
        // A timeout means "busy", not "not a window": it already came from the window list.
        if !strict, roleErr == .cannotComplete || subErr == .cannotComplete { return true }
        guard role == kAXWindowRole as String else { return false }
        return sub == kAXStandardWindowSubrole as String || sub == kAXDialogSubrole as String
    }

    struct CGInfo {
        /// Front-to-back index of on-screen, layer-0 windows.
        var zOrder: [CGWindowID: Int] = [:]
        /// Plausible app windows per pid, including ones on other Spaces.
        var candidates: [pid_t: Set<CGWindowID>] = [:]
    }

    private static func cgWindows() -> CGInfo {
        var info = CGInfo()
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for (i, d) in list.enumerated() where (d[kCGWindowLayer as String] as? Int) == 0 {
                if let n = d[kCGWindowNumber as String] as? UInt32 { info.zOrder[n] = i }
            }
        }
        if let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] {
            for d in list where (d[kCGWindowLayer as String] as? Int) == 0 {
                guard let n = d[kCGWindowNumber as String] as? UInt32,
                      let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                      (d[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                      let b = d[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: b),
                      r.width >= 100, r.height >= 100 else { continue }
                info.candidates[pid, default: []].insert(n)
            }
        }
        return info
    }
}
