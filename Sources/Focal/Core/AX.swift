import ApplicationServices
import CoreGraphics

/// Private but long-stable Accessibility symbol that maps an AXUIElement window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Private: builds an AXUIElement from a remote token. Used to reach windows on other Spaces,
/// which kAXWindowsAttribute does not return.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Thin helpers over the verbose C Accessibility API.
enum AX {
    static func value<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// Like `value`, but also reports the error so callers can tell "absent" from "timed out".
    static func read<T>(_ el: AXUIElement, _ attr: String) -> (T?, AXError) {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        return (err == .success ? v as? T : nil, err)
    }

    /// Element `elementID` of app `pid`, addressed directly (token layout: pid, 0, 'coco', id).
    static func element(pid: pid_t, elementID: UInt64) -> AXUIElement? {
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { b in
            b.storeBytes(of: pid, toByteOffset: 0, as: pid_t.self)
            b.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            b.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)
            b.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
        }
        return _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue()
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool {
        (value(el, attr) as Bool?) ?? false
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// Frame in AX/CG coordinates (origin top-left of the primary display).
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p: AXValue = value(el, kAXPositionAttribute),
              let s: AXValue = value(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &pt), AXValueGetValue(s, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// Size -> position -> size: the first size lets the move land on another display,
    /// the last one corrects for apps that clamp size relative to position.
    static func setFrame(_ el: AXUIElement, _ rect: CGRect) {
        var pt = rect.origin, sz = rect.size
        guard let pv = AXValueCreate(.cgPoint, &pt), let sv = AXValueCreate(.cgSize, &sz) else { return }
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
    }
}
