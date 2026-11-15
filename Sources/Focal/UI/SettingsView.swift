import SwiftUI
import AppKit

struct ShortcutsView: View {
    @ObservedObject var store: ShortcutStore
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ShortcutAction.allCases) { a in
                ShortcutRow(store: store, action: a)
            }
            Text("Click a shortcut, then press the new combination (Esc cancels). Add ⇧ to the switcher shortcut to cycle backwards.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutRow: View {
    @ObservedObject var store: ShortcutStore
    let action: ShortcutAction
    @State private var recording = false
    @State private var error: String?
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.title).frame(width: 130, alignment: .leading)
            Button(recording ? "Press keys…" : store[action].display) { recording ? stop() : start() }
                .frame(minWidth: 110)
                .buttonStyle(.bordered)
                .tint(recording ? .accentColor : nil)
            Button { store.reset(action); error = nil } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).help("Reset to default")
                .disabled(store[action] == action.defaultShortcut)
            if let error { Text("Used by “\(error)”").font(.caption).foregroundStyle(.red) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        error = nil
        recording = true
        store.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let code = Int(ev.keyCode)
            let mods = Mods(ns: ev.modifierFlags)
            if code == 53 && mods.isEmpty { stop(); return nil }
            // Require a modifier so plain typing can never be hijacked.
            guard !mods.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }
            if let clash = store.set(Shortcut(keyCode: code, mods: mods), for: action) { error = clash } else { error = nil }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        store.isRecording = false
    }
}
