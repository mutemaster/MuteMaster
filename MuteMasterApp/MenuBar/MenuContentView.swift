//
//  MenuContentView.swift
//  The dropdown shown when the user clicks the menu-bar icon: mute toggles, device pickers,
//  shortcut recorders, driver install status, and Quit.
//

import SwiftUI
import KeyboardShortcuts

struct MenuContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            if !state.driverInstalled {
                DriverInstallBanner(state: state)
                Divider()
            }

            // ---- Mute toggles ----
            muteToggle(title: "Mute Input (microphone)",
                       icon: state.inputMuted ? "mic.slash.fill" : "mic.fill",
                       isOn: Binding(get: { state.inputMuted }, set: { state.setInputMuted($0) }))
            muteToggle(title: "Mute Output (speakers)",
                       icon: state.outputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       isOn: Binding(get: { state.outputMuted }, set: { state.setOutputMuted($0) }))

            Divider()

            // ---- Real device patching ----
            VStack(alignment: .leading, spacing: 6) {
                Text("Patch real devices").font(.caption).foregroundStyle(.secondary)

                Picker("Microphone in:", selection: Binding(
                    get: { state.selectedInputUID ?? "" },
                    set: { state.selectInput(uid: $0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(state.inputDevices.filter { $0.uid != ZMIdentifiers.mutableInputUID }) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }

                Picker("Speakers out:", selection: Binding(
                    get: { state.selectedOutputUID ?? "" },
                    set: { state.selectOutput(uid: $0.isEmpty ? nil : $0) })) {
                    Text("None").tag("")
                    ForEach(state.outputDevices.filter { $0.uid != ZMIdentifiers.mutableOutputUID }) { dev in
                        Text(dev.name).tag(dev.uid)
                    }
                }
            }

            Divider()

            // ---- Global shortcuts ----
            // Show the current bindings read-only here; editing happens in a separate window (see
            // ShortcutsSettingsView) so the library's conflict alert can't collapse this panel.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Global shortcuts", systemImage: "keyboard")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Shortcuts…") {
                        openWindow(id: MuteMasterApp.shortcutsWindowID)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                shortcutRow("Toggle input mute", name: .toggleInputMute)
                shortcutRow("Toggle output mute", name: .toggleOutputMute)
            }

            Divider()

            HStack {
                Button("Refresh Devices") { state.refreshDevices() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            Button("Acknowledgements & Licenses…") {
                openWindow(id: MuteMasterApp.acknowledgementsWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }

    /// A mute switch with a fixed-width icon slot (so the label doesn't shift when the symbol
    /// changes width between states) that fills the row width so the switch sits flush right.
    @ViewBuilder
    private func muteToggle(title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 24, alignment: .center)
                Text(title)
            }
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity)
    }

    /// One read-only "label: ⌘…" row showing the current binding for a shortcut (or "Not set").
    @ViewBuilder
    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        let combo = KeyboardShortcuts.getShortcut(for: name)?.description
        HStack {
            Text(title).font(.caption)
            Spacer()
            Text(combo ?? "Not set")
                .font(.caption.monospaced())
                .foregroundStyle(combo == nil ? .secondary : .primary)
        }
    }
}

/// Shown at the top of the menu when our virtual devices aren't visible yet.
struct DriverInstallBanner: View {
    @ObservedObject var state: AppState
    @StateObject private var installer = DriverInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Driver not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The Mutable Microphone and Mutable Speaker devices aren't available yet. Install the audio driver to enable patching and muting.")
                .font(.caption).foregroundStyle(.secondary)
            if let status = installer.statusMessage {
                Text(status).font(.caption2).foregroundStyle(.secondary)
            }
            Button(installer.isWorking ? "Installing…" : "Install Driver") {
                installer.installDriver { _ in state.refreshDevices() }
            }
            .disabled(installer.isWorking)
        }
    }
}
