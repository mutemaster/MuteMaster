//
//  MuteMasterApp.swift
//  App entry point. This is a menu-bar-only app (LSUIElement = YES, set in Info.plist), so there's
//  no Dock icon and no main window — just a MenuBarExtra living in the system menu bar.
//

import SwiftUI

@main
struct MuteMasterApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)   // .window lets us use rich SwiftUI controls in the dropdown

        // Shortcut configuration lives in its own window so the library's "shortcut already taken"
        // alert doesn't collapse the menu panel. Opened from the menu via openWindow(id:).
        Window("MuteMaster Shortcuts", id: Self.shortcutsWindowID) {
            ShortcutsSettingsView(state: state)
        }
        .windowResizability(.contentSize)

        // Bundled open-source license notices.
        Window("Acknowledgements & Licenses", id: Self.acknowledgementsWindowID) {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }

    static let shortcutsWindowID = "shortcuts"
    static let acknowledgementsWindowID = "acknowledgements"
}
