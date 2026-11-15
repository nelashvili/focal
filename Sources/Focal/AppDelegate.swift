import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let permissions = PermissionsManager()
    private let store = WindowStore()
    private let snapper = WindowSnapper()
    private let shortcuts = ShortcutStore()
    private lazy var hotkeys = HotkeyManager(shortcuts: shortcuts)
    private lazy var switcher = SwitcherController(store: store)
    private var statusItem: NSStatusItem!
    private var onboardingWindow: NSWindow?
    private var loginItem: NSMenuItem!
    private var snapItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeys.handlers = .init(
            isSwitcherActive: { [unowned self] in switcher.isActive },
            begin: { [unowned self] in switcher.begin(reverse: $0) },
            move: { [unowned self] in switcher.move($0) },
            moveRow: { [unowned self] in switcher.moveRow($0) },
            commit: { [unowned self] in switcher.commit() },
            cancel: { [unowned self] in switcher.cancel() },
            snap: { [unowned self] in snapper.snap($0) })

        permissions.onGranted = { [weak self] in self?.startEngine() }
        buildStatusItem()

        if permissions.refresh() { startEngine() }
        if !permissions.accessibilityGranted || !UserDefaults.standard.bool(forKey: "onboardingDone") {
            showOnboarding()
        }
    }

    private func startEngine() {
        if !hotkeys.isRunning {
            store.start()
            let ok = hotkeys.start()
            Log.write("startEngine: AXIsProcessTrusted=\(AXIsProcessTrusted()) listenAccess=\(CGPreflightListenEventAccess()) tapCreated=\(ok)")
        }
    }

    // MARK: Onboarding

    @objc func showOnboarding() {
        if let w = onboardingWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let view = OnboardingView(permissions: permissions, shortcuts: shortcuts) { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboardingDone")
            self?.onboardingWindow?.close()
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Focal"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        onboardingWindow = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingWindow = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Focal")

        let menu = NSMenu()
        for action in ShortcutAction.allCases where action.snap != nil {
            let item = NSMenuItem(title: action.title, action: #selector(menuSnap(_:)), keyEquivalent: "")
            item.representedObject = action.rawValue
            item.target = self
            snapItems.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        let setup = NSMenuItem(title: "Shortcuts & Setup…", action: #selector(showOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Focal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func menuSnap(_ sender: NSMenuItem) {
        // Menu steals focus from nothing (accessory app), so the frontmost app is still the user's.
        guard let raw = sender.representedObject as? String, let a = ShortcutAction(rawValue: raw)?.snap else { return }
        snapper.snap(a)
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        try? (svc.status == .enabled ? svc.unregister() : svc.register())
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in snapItems {
            if let a = (item.representedObject as? String).flatMap(ShortcutAction.init(rawValue:)) {
                item.title = "\(a.title)    \(shortcuts[a].display)"
            }
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
