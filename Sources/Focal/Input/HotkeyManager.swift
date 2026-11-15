import AppKit
import CoreGraphics

/// Single session-level CGEventTap. Pure state machine; owns no UI.
///
///  - Switcher shortcut (default Opt+Tab; Shift reverses): hold the modifiers, release to focus.
///  - While open: switcher key/arrows move, Return focuses, Esc cancels.
///  - Snap shortcuts (defaults Opt+Shift+Left / Right / Up). All bindings come from ShortcutStore.
@MainActor
final class HotkeyManager {
    struct Handlers {
        var isSwitcherActive: () -> Bool
        var begin: (_ reverse: Bool) -> Void
        var move: (_ delta: Int) -> Void
        var moveRow: (_ delta: Int) -> Void
        var commit: () -> Void
        var cancel: () -> Void
        var snap: (SnapAction) -> Void
    }

    private enum Key { static let tab = 48, esc = 53, ret = 36, enter = 76, left = 123, right = 124, down = 125, up = 126 }

    var handlers: Handlers!
    let shortcuts: ShortcutStore

    init(shortcuts: ShortcutStore) { self.shortcuts = shortcuts }
    private var tap: CFMachPort?

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        return true
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        if shortcuts.isRecording { return false }
        let flags = event.flags
        let mods = Mods(cg: flags)
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let active = handlers.isSwitcherActive()

        switch type {
        case .flagsChanged:
            let required = shortcuts[.switcher].mods.subtracting(.shift)
            if active && !mods.isSuperset(of: required) { handlers.commit() }
            return false

        case .keyUp:
            return active // keep stray key-ups from reaching the app underneath

        case .keyDown:
            if active {
                switch key {
                case shortcuts[.switcher].keyCode: handlers.move(mods.contains(.shift) ? -1 : 1)
                case Key.left: handlers.move(-1)
                case Key.right: handlers.move(1)
                case Key.up: handlers.moveRow(-1)
                case Key.down: handlers.moveRow(1)
                case Key.ret, Key.enter: handlers.commit()
                case Key.esc: handlers.cancel()
                default: break
                }
                return true
            }

            guard let (action, reverse) = shortcuts.match(key: key, mods: mods) else { return false }
            if let snap = action.snap { handlers.snap(snap) } else { handlers.begin(reverse) }
            return true

        default:
            return false
        }
    }
}

private func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                         _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { mgr.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
