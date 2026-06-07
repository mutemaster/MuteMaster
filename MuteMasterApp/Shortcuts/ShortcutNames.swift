//
//  ShortcutNames.swift
//  Names for the two user-configurable global shortcuts. KeyboardShortcuts persists the chosen key
//  combination for each name in UserDefaults automatically, and uses Carbon's RegisterEventHotKey
//  under the hood — so toggling mute needs NO Accessibility or Input-Monitoring permission.
//

import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleInputMute  = Self("toggleInputMute")
    static let toggleOutputMute = Self("toggleOutputMute")
}
