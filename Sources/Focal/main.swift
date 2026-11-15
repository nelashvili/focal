import AppKit

// `Focal --dump` prints the discovered windows and exits (handy for debugging permissions/enumeration).
if CommandLine.arguments.contains("--dump") {
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    let ws = WindowDiscoveryEngine().enumerateSync()
    for w in ws {
        print(String(format: "%6d  z=%-10d %@ — %@%@%@", w.id, w.zIndex == .max ? -1 : w.zIndex, w.appName, w.title,
                     w.isMinimized ? " [minimized]" : "", w.isAppHidden ? " [hidden]" : ""))
    }
    print("\(ws.count) windows")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
