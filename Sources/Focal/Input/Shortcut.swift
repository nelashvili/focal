import AppKit

struct Mods: OptionSet, Codable, Hashable {
    let rawValue: UInt8
    static let command = Mods(rawValue: 1), option = Mods(rawValue: 2)
    static let control = Mods(rawValue: 4), shift = Mods(rawValue: 8)

    init(rawValue: UInt8) { self.rawValue = rawValue }
    init(cg f: CGEventFlags) {
        var m: Mods = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskShift) { m.insert(.shift) }
        self = m
    }
    init(ns f: NSEvent.ModifierFlags) {
        var m: Mods = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.option) { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        if f.contains(.shift) { m.insert(.shift) }
        self = m
    }
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") +
        (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

struct Shortcut: Codable, Hashable {
    var keyCode: Int
    var mods: Mods

    var display: String { mods.symbols + " " + Self.keyName(keyCode) }

    static func keyName(_ code: Int) -> String {
        let names: [Int: String] = [
            123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 76: "↩", 48: "Tab", 49: "Space", 53: "Esc", 51: "⌫",
            0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
            46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
            7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8",
            25: "9", 29: "0", 50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\",
        ]
        return names[code] ?? "Key \(code)"
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case switcher, snapLeft, snapRight, maximize
    var id: String { rawValue }

    var title: String {
        switch self {
        case .switcher: "Switch windows"
        case .snapLeft: "Snap left half"
        case .snapRight: "Snap right half"
        case .maximize: "Maximize"
        }
    }
    var snap: SnapAction? {
        switch self {
        case .snapLeft: .leftHalf
        case .snapRight: .rightHalf
        case .maximize: .maximize
        case .switcher: nil
        }
    }
    var defaultShortcut: Shortcut {
        switch self {
        case .switcher: Shortcut(keyCode: 48, mods: [.option])
        case .snapLeft: Shortcut(keyCode: 123, mods: [.option, .shift])
        case .snapRight: Shortcut(keyCode: 124, mods: [.option, .shift])
        case .maximize: Shortcut(keyCode: 126, mods: [.option, .shift])
        }
    }
}

/// User-editable bindings, persisted in UserDefaults.
@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var bindings: [ShortcutAction: Shortcut]
    /// While true the event tap lets everything through so the recorder can see keys.
    var isRecording = false
    private let key = "shortcuts.v1"

    init() {
        var b = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([ShortcutAction: Shortcut].self, from: data) {
            b.merge(saved) { _, new in new }
        }
        bindings = b
    }

    subscript(_ a: ShortcutAction) -> Shortcut { bindings[a]! }

    /// Returns the conflicting action's title if `s` is already taken.
    @discardableResult
    func set(_ s: Shortcut, for a: ShortcutAction) -> String? {
        if let other = ShortcutAction.allCases.first(where: { $0 != a && conflicts(self[$0], s) }) { return other.title }
        bindings[a] = s
        persist()
        return nil
    }

    func reset(_ a: ShortcutAction) { bindings[a] = a.defaultShortcut; persist() }

    private func conflicts(_ a: Shortcut, _ b: Shortcut) -> Bool {
        a.keyCode == b.keyCode && (a.mods == b.mods || a.mods.symmetricDifference(b.mods) == .shift)
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// Matches a key-down. For the switcher, adding Shift to its modifiers means "reverse".
    func match(key: Int, mods: Mods) -> (ShortcutAction, reverse: Bool)? {
        for a in ShortcutAction.allCases {
            let s = self[a]
            guard s.keyCode == key else { continue }
            if mods == s.mods { return (a, false) }
            if a == .switcher, !s.mods.contains(.shift), mods == s.mods.union(.shift) { return (a, true) }
        }
        return nil
    }
}
