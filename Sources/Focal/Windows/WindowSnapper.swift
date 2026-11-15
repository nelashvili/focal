import AppKit

enum SnapAction: String, CaseIterable {
    case leftHalf = "Left Half"
    case rightHalf = "Right Half"
    case maximize = "Maximize"
}

/// Moves/resizes the focused window. Pressing the same action twice restores the original frame.
@MainActor
final class WindowSnapper {
    private var originals: [CGWindowID: CGRect] = [:]

    func snap(_ action: SnapAction) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        guard let win: AXUIElement = AX.value(appEl, kAXFocusedWindowAttribute),
              !AX.bool(win, "AXFullScreen"),
              let current = AX.frame(win) else { return }

        let id = AX.windowID(win)
        let area = Self.visibleArea(containing: current)
        let target: CGRect
        switch action {
        case .leftHalf:  target = CGRect(x: area.minX, y: area.minY, width: (area.width / 2).rounded(.down), height: area.height)
        case .rightHalf:
            let w = (area.width / 2).rounded(.down)
            target = CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height)
        case .maximize:  target = area
        }

        if let id, Self.close(current, target), let saved = originals[id] {
            AX.setFrame(win, saved)
            originals[id] = nil
            return
        }
        if let id, !Self.close(current, target) {
            if originals[id] == nil || !Self.isSnapFrame(current) { originals[id] = current }
        }
        AX.setFrame(win, target)
    }

    // MARK: Geometry (AX coordinates: origin top-left of primary display, y down)

    private static func axRect(_ r: CGRect) -> CGRect {
        let primaryH = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
    }

    /// The usable area (minus menu bar / Dock) of the display holding most of `window`.
    private static func visibleArea(containing window: CGRect) -> CGRect {
        let best = NSScreen.screens.max { a, b in
            axRect(a.frame).intersection(window).area < axRect(b.frame).intersection(window).area
        } ?? NSScreen.main
        return axRect((best ?? NSScreen.screens[0]).visibleFrame)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8 && abs(a.width - b.width) < 8 && abs(a.height - b.height) < 8
    }

    private static func isSnapFrame(_ r: CGRect) -> Bool {
        let area = visibleArea(containing: r)
        return [CGRect(x: area.minX, y: area.minY, width: area.width / 2, height: area.height),
                CGRect(x: area.maxX - area.width / 2, y: area.minY, width: area.width / 2, height: area.height),
                area].contains { close(r, $0) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
