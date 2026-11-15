import AppKit
import ScreenCaptureKit

/// Captures small, GPU-backed window snapshots with ScreenCaptureKit.
/// Runs only when the switcher opens (nothing happens at rest); results are cached by the caller.
@MainActor
enum ThumbnailProvider {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Streams images back as each capture finishes, in the order given (most recent first).
    static func capture(ids: [CGWindowID], maxPixelWidth: Int = 520,
                        update: @escaping @MainActor (CGWindowID, NSImage) -> Void) {
        guard isAuthorized, !ids.isEmpty else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in ids {
                    guard let w = byID[id], w.frame.width > 1, w.frame.height > 1 else { continue }
                    group.addTask {
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, Double(maxPixelWidth) / w.frame.width)
                        cfg.width = max(1, Int(w.frame.width * scale))
                        cfg.height = max(1, Int(w.frame.height * scale))
                        cfg.showsCursor = false
                        let img = try? await SCScreenshotManager.captureImage(
                            contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
                        return (id, img)
                    }
                }
                for await (id, img) in group {
                    if let img { update(id, NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) }
                }
            }
        }
    }
}
