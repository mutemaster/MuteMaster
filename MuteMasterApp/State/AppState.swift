//
//  AppState.swift
//  The app's single source of UI truth. Bridges user actions (menu clicks, global hotkeys) to the
//  RoutingEngine, persists device choices, and reacts to device hot-plug.
//
//  @MainActor + ObservableObject: SwiftUI views observe the @Published properties and update the
//  menu-bar icons automatically when mute state changes.
//

import Foundation
import Combine
import CoreAudio
import KeyboardShortcuts

@MainActor
final class AppState: ObservableObject {
    @Published var inputMuted = false
    @Published var outputMuted = false

    @Published var inputDevices: [AudioDeviceInfo] = []
    @Published var outputDevices: [AudioDeviceInfo] = []

    @Published var selectedInputUID: String?
    @Published var selectedOutputUID: String?

    /// True once the virtual devices from our driver are visible to Core Audio.
    @Published var driverInstalled = false

    let engine = RoutingEngine()
    private let defaults = UserDefaults.standard
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    init() {
        selectedInputUID = defaults.string(forKey: ZMDefaultsKey.realInputDeviceUID)
        selectedOutputUID = defaults.string(forKey: ZMDefaultsKey.realOutputDeviceUID)

        refreshDevices()

        // When the app is launched as the XCTest host, do NOT start the real engine. Otherwise the
        // host app's routing would (a) fight the test's own engine for the virtual devices and
        // (b) route the tests' injected tone to your real speakers. The tests build their own engine.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            registerHotkeys()
            observeDeviceChanges()
            applyConfigurationAndStart()
        }
    }

    // MARK: - Device list

    func refreshDevices() {
        inputDevices = DeviceEnumerator.inputDevices()
        outputDevices = DeviceEnumerator.outputDevices()
        let all = DeviceEnumerator.allDevices().map(\.uid)
        driverInstalled = all.contains(ZMIdentifiers.mutableInputUID) && all.contains(ZMIdentifiers.mutableOutputUID)
    }

    func selectInput(uid: String?) {
        selectedInputUID = uid
        defaults.set(uid, forKey: ZMDefaultsKey.realInputDeviceUID)
        applyConfigurationAndStart()
    }

    func selectOutput(uid: String?) {
        selectedOutputUID = uid
        defaults.set(uid, forKey: ZMDefaultsKey.realOutputDeviceUID)
        applyConfigurationAndStart()
    }

    // MARK: - Engine lifecycle

    func applyConfigurationAndStart() {
        engine.configure(realInputUID: selectedInputUID, realOutputUID: selectedOutputUID)
        engine.setInputMuted(inputMuted)
        engine.setOutputMuted(outputMuted)
        engine.start()
    }

    // MARK: - Mute

    func toggleInputMute()  { setInputMuted(!inputMuted) }
    func toggleOutputMute() { setOutputMuted(!outputMuted) }

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        engine.setInputMuted(muted)
    }

    func setOutputMuted(_ muted: Bool) {
        outputMuted = muted
        engine.setOutputMuted(muted)
    }

    // MARK: - Global hotkeys

    /// Called when the user records/clears a global shortcut in the Shortcuts window. The
    /// KeyboardShortcuts library persists the new binding itself; this just nudges SwiftUI so
    /// views that display the current binding (the menu panel's read-only rows) re-render —
    /// they read `KeyboardShortcuts.getShortcut(for:)`, which isn't an observable source.
    func shortcutsDidChange() {
        objectWillChange.send()
    }

    private func registerHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .toggleInputMute) { [weak self] in
            Task { @MainActor in self?.toggleInputMute() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleOutputMute) { [weak self] in
            Task { @MainActor in self?.toggleOutputMute() }
        }
    }

    // MARK: - Device hot-plug

    private func observeDeviceChanges() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.applyConfigurationAndStart()
            }
        }
        deviceListListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }
}
