import AppKit

struct WindowInfo: Identifiable, @unchecked Sendable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleID: String?
    let title: String
    let icon: NSImage?
    let isMinimized: Bool
    let isAppHidden: Bool
    /// Front-to-back index among on-screen windows (Int.max when off-screen).
    let zIndex: Int
    let axWindow: AXUIElement

    var displayTitle: String { title.isEmpty ? appName : title }
}
