//
//  RoutingEngine.swift
//  Owns the two audio paths and exposes simple start/stop/mute controls to the rest of the app.
//
//    inputPath : real mic  ──▶ "Mutable Microphone"   (so Zoom etc. read the real mic from it)
//    outputPath: "Mutable Speaker" ──▶ real speakers (so Zoom's audio reaches the speakers)
//
//  Mute is enforced inside each path's playback callback (see AUHALUnit.renderCallback) — a single
//  source of truth that works even if a downstream app ignores its own mute button.
//

import Foundation
import CoreAudio
import os

@MainActor
final class RoutingEngine {
    private var inputPath: AudioPath?
    private var outputPath: AudioPath?
    private let log = Logger(subsystem: ZMIdentifiers.appBundleID, category: "engine")

    private(set) var isRunning = false

    /// True when the corresponding virtual + real devices were found and the path was built.
    var hasInputPath: Bool { inputPath != nil }
    var hasOutputPath: Bool { outputPath != nil }

    /// (Re)build both paths from the selected real-device UIDs. Tears down any running paths first.
    /// A path is skipped (left nil) if either of its devices can't be resolved right now.
    func configure(realInputUID: String?, realOutputUID: String?) {
        stop()

        let virtualInID  = DeviceEnumerator.deviceID(forUID: ZMIdentifiers.mutableInputUID)
        let virtualOutID = DeviceEnumerator.deviceID(forUID: ZMIdentifiers.mutableOutputUID)

        // Input path: real mic → Mutable Microphone.
        if let realInUID = realInputUID,
           let realInID = DeviceEnumerator.deviceID(forUID: realInUID),
           let mutableInID = virtualInID {
            do {
                inputPath = try AudioPath(label: "input", sourceDeviceID: realInID, destDeviceID: mutableInID)
            } catch {
                log.error("Failed to build input path: \(String(describing: error), privacy: .public)")
                inputPath = nil
            }
        } else {
            inputPath = nil
        }

        // Output path: Mutable Speaker → real speakers.
        if let realOutUID = realOutputUID,
           let realOutID = DeviceEnumerator.deviceID(forUID: realOutUID),
           let mutableOutID = virtualOutID {
            do {
                outputPath = try AudioPath(label: "output", sourceDeviceID: mutableOutID, destDeviceID: realOutID)
            } catch {
                log.error("Failed to build output path: \(String(describing: error), privacy: .public)")
                outputPath = nil
            }
        } else {
            outputPath = nil
        }
    }

    func start() {
        do { try inputPath?.start() } catch { log.error("input start: \(String(describing: error), privacy: .public)") }
        do { try outputPath?.start() } catch { log.error("output start: \(String(describing: error), privacy: .public)") }
        isRunning = true
    }

    func stop() {
        inputPath?.stop()
        outputPath?.stop()
        isRunning = false
    }

    func setInputMuted(_ muted: Bool)  { inputPath?.setMuted(muted) }
    func setOutputMuted(_ muted: Bool) { outputPath?.setMuted(muted) }

    var inputRingFill: UInt32  { inputPath?.ringFillFrames ?? 0 }
    var outputRingFill: UInt32 { outputPath?.ringFillFrames ?? 0 }
}
