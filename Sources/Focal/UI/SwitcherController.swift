import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowInfo] = []
    @Published var selected = 0
    @Published var thumbs: [CGWindowID: NSImage] = [:]
    @Published var showThumbnails = false
    var columns = 1
    var cardWidth: CGFloat = 230
}

/// Non-activating HUD: created once, reused, so showing it is just orderFront.
@MainActor
final class SwitcherController {
    private let store: WindowStore
    private let model = SwitcherModel()
    private let panel: NSPanel
    private(set) var isActive = false
    private var navigated = false

    private let gap: CGFloat = 12
    private let pad: CGFloat = 16

    init(store: WindowStore) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: SwitcherView(model: model, onPick: { [weak self] i in
            self?.model.selected = i
            self?.commit()
        }))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    func begin(reverse: Bool) {
        let ws = store.windows
        guard !ws.isEmpty else { return }
        isActive = true
        navigated = false
        model.showThumbnails = ThumbnailProvider.isAuthorized
        model.windows = ws
        model.selected = Self.initialSelection(count: ws.count, reverse: reverse)
        present()
        captureThumbnails(for: ws)
        Log.write("begin sel=\(model.selected) order=" + ws.prefix(8).map { "\($0.appName.prefix(6)):\($0.id)" }.joined(separator: " "))

        // Reconcile with fresh data a few ms later without yanking the selection.
        store.refresh { [weak self] fresh in
            guard let self, self.isActive else { return }
            let keep = self.model.windows.indices.contains(self.model.selected) ? self.model.windows[self.model.selected].id : nil
            self.model.windows = fresh
            if self.navigated, let keep, let i = fresh.firstIndex(where: { $0.id == keep }) {
                self.model.selected = i
            } else {
                self.model.selected = Self.initialSelection(count: fresh.count, reverse: reverse)
            }
            self.present()
            self.captureThumbnails(for: fresh.filter { self.model.thumbs[$0.id] == nil })
        }
    }

    private func captureThumbnails(for ws: [WindowInfo]) {
        guard model.showThumbnails else { return }
        // Drop cache entries for windows that no longer exist.
        let live = Set(store.windows.map(\.id)).union(ws.map(\.id))
        model.thumbs = model.thumbs.filter { live.contains($0.key) }
        ThumbnailProvider.capture(ids: ws.map(\.id)) { [weak self] id, img in self?.model.thumbs[id] = img }
    }

    func move(_ delta: Int) {
        guard isActive, !model.windows.isEmpty else { return }
        navigated = true
        let n = model.windows.count
        model.selected = ((model.selected + delta) % n + n) % n
    }

    func moveRow(_ dir: Int) {
        guard isActive, !model.windows.isEmpty else { return }
        navigated = true
        let next = model.selected + dir * model.columns
        if model.windows.indices.contains(next) { model.selected = next }
    }

    func commit() {
        guard isActive else { return }
        isActive = false
        panel.orderOut(nil)
        guard model.windows.indices.contains(model.selected) else { return }
        let w = model.windows[model.selected]
        Log.write("commit idx=\(model.selected) -> \(w.appName.prefix(6)):\(w.id) min=\(w.isMinimized)")
        store.noteFocused(w.id)
        WindowFocuser.focus(w)
    }

    func cancel() {
        isActive = false
        panel.orderOut(nil)
    }

    private static func initialSelection(count: Int, reverse: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reverse ? count - 1 : 1
    }

    /// Auto-size: as many columns as fit, shrinking cards when many windows are open.
    private func present() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let f = screen.visibleFrame
        let n = model.windows.count
        let maxW = f.width * 0.9, maxH = f.height * 0.8

        var cardW: CGFloat = 240
        var cols = 1, rows = 1
        func layout() {
            cols = max(1, min(n, Int((maxW - 2 * pad + gap) / (cardW + gap))))
            rows = Int(ceil(Double(n) / Double(cols)))
        }
        layout()
        while cardW > 150, CGFloat(rows) * (Self.cardHeight(cardW) + gap) - gap + 2 * pad > maxH {
            cardW -= 10
            layout()
        }
        model.columns = cols
        model.cardWidth = cardW

        let w = CGFloat(cols) * cardW + CGFloat(cols - 1) * gap + 2 * pad
        let h = min(CGFloat(rows) * (Self.cardHeight(cardW) + gap) - gap + 2 * pad, maxH)
        panel.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2 + f.height * 0.05, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    static func cardHeight(_ cardW: CGFloat) -> CGFloat { thumbHeight(cardW) + 16 + 8 + 22 }
    static func thumbHeight(_ cardW: CGFloat) -> CGFloat { (cardW - 16) * 0.62 }
}
