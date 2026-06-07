//
//  ShortcutsSettingsView.swift
//  A normal window for recording the global shortcuts. We keep this OUT of the MenuBarExtra panel
//  because KeyboardShortcuts shows a modal alert when you pick a combo that's already taken (e.g.
//  ⌘M = Minimize). A modal over the menu panel makes SwiftUI auto-close the panel; in a regular
//  window the alert is harmless.
//
//  Because this is a menu-bar (accessory) app, we temporarily switch the activation policy to
//  .regular while the window is open so it can take keyboard focus (needed to record shortcuts),
//  then back to .accessory when it closes (so no Dock icon lingers).
//

import SwiftUI
import KeyboardShortcuts
import AppKit

struct ShortcutsSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Global Shortcuts")
                .font(.headline)
            Text("Pick a key combination for each. If a combo is already used by a menu or the system, macOS will say so — just choose another.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // onChange fires after the library has persisted the new binding; we forward it to
            // AppState so the menu panel's read-only shortcut rows refresh (see shortcutsDidChange).
            Form {
                KeyboardShortcuts.Recorder("Toggle input mute:", name: .toggleInputMute) { _ in
                    state.shortcutsDidChange()
                }
                KeyboardShortcuts.Recorder("Toggle output mute:", name: .toggleOutputMute) { _ in
                    state.shortcutsDidChange()
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
