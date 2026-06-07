//
//  AudioPath.swift
//  One unidirectional audio route: capture from a SOURCE device → ring buffer → play to a DEST
//  device. Owns the shared ring and the mute flag for this direction.
//
//  Used twice by RoutingEngine:
//    • Input path : source = real mic,            dest = "Mutable Microphone"  (virtual mic feed)
//    • Output path: source = "Mutable Speaker", dest = real speakers
//
//  Clock drift: the source and dest devices run on independent clocks. AUHAL resamples each device
//  to our common 48 kHz, but the two clocks still differ by a few ppm, so the ring's fill level
//  slowly drifts. The ring absorbs jitter and bounds latency (overflow drops oldest, underrun
//  zero-fills). For higher-fidelity long-run correction see DriftCorrector and the README notes.
//

import Foundation
import CoreAudio

final class AudioPath {
    private let ring: RingBuffer
    private let mutePtr: UnsafeMutablePointer<Int32>
    private var capture: AUHALUnit?
    private var playback: AUHALUnit?
    let label: String

    /// Ring capacity in frames (power of two). ~0.34 s at 48 kHz — plenty for scheduling jitter.
    private static let ringCapacityFrames: UInt32 = 16384

    init(label: String, sourceDeviceID: AudioObjectID, destDeviceID: AudioObjectID) throws {
        self.label = label
        guard let ring = RingBuffer(capacityFrames: Self.ringCapacityFrames, channels: EngineFormat.channels) else {
            throw EngineError.osStatus("RingBuffer.init", -1)
        }
        self.ring = ring
        self.mutePtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.mutePtr.initialize(to: 0)

        // Prime the ring half-full with silence so playback doesn't underrun before capture fills it.
        let halfFrames = Self.ringCapacityFrames / 2
        let silence = [Float](repeating: 0, count: Int(halfFrames * EngineFormat.channels))
        ring.write(silence, frameCount: halfFrames)

        self.capture = try AUHALUnit(mode: .capture, deviceID: sourceDeviceID, ring: ring.pointer, mutePtr: nil)
        self.playback = try AUHALUnit(mode: .playback, deviceID: destDeviceID, ring: ring.pointer, mutePtr: mutePtr)
    }

    func start() throws {
        // Start playback first so it's ready to consume as soon as capture produces.
        try playback?.start()
        try capture?.start()
    }

    func stop() {
        capture?.stop()
        playback?.stop()
    }

    /// Thread-safe enough for a single boolean flag: a 32-bit aligned store is atomic on arm64/x86_64.
    func setMuted(_ muted: Bool) {
        mutePtr.pointee = muted ? 1 : 0
    }

    var isMuted: Bool { mutePtr.pointee != 0 }

    /// Current ring fill in frames — used by the drift soak test / diagnostics.
    var ringFillFrames: UInt32 { ring.fillFrames }

    deinit {
        capture?.stop()
        playback?.stop()
        capture = nil
        playback = nil
        mutePtr.deinitialize(count: 1)
        mutePtr.deallocate()
    }
}
