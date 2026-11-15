import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    @ObservedObject var shortcuts: ShortcutStore
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 34)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Welcome to Focal").font(.title.bold())
                    Text("Fast window switching and snapping. Everything stays on your Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionCard(
                granted: permissions.accessibilityGranted,
                title: "Accessibility access",
                detail: "Needed to see, raise and resize windows, and to listen for your shortcuts.",
                grantedDetail: "Granted.",
                optional: false
            ) {
                permissions.requestAccessibility()
                permissions.openAccessibilitySettings()
            }

            PermissionCard(
                granted: permissions.screenRecordingGranted,
                title: "Screen Recording (optional)",
                detail: "Shows a live preview of each window. Without it Focal shows app icons. You may need to reopen Focal after granting.",
                grantedDetail: "Granted. Window previews are on.",
                optional: true
            ) {
                permissions.requestScreenRecording()
                permissions.openScreenRecordingSettings()
            }

            Text("In System Settings → Privacy & Security, switch Focal on. This page updates automatically.")
                .font(.footnote).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Shortcuts").font(.headline)
                ShortcutsView(store: shortcuts)
            }

            HStack {
                Spacer()
                Button("Get Started", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.accessibilityGranted)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

private struct PermissionCard: View {
    let granted: Bool
    let title: String
    let detail: String
    let grantedDetail: String
    let optional: Bool
    let action: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "hand.raised.circle.fill"))
                    .font(.system(size: 26))
                    .foregroundStyle(granted ? .green : (optional ? .secondary : .orange))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(granted ? grantedDetail : detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !granted {
                    if optional { Button("Enable", action: action) } else { Button("Grant Access", action: action).buttonStyle(.borderedProminent) }
                }
            }
            .padding(6)
        }
    }
}
