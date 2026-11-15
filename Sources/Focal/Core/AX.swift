import ApplicationServices
import CoreGraphics

/// Private but long-stable Accessibility symbol that maps an AXUIElement window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin helpers over the verbose C Accessibility API.
enum AX {
    static func value<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? T
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
