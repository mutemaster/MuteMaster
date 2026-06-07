//
//  AudioIntegrationTests.swift
//  Tone-based integration tests that exercise the REAL driver + routing engine — no human listening
//  and no real microphone/speakers required, because the two virtual loopback devices double as
//  programmable tone injection and capture points.
//
//  These require the driver to be installed (Scripts/sign_and_install.sh). If the virtual devices
//  aren't present, every test here calls XCTSkip, so the suite stays green on machines without it.
//

import XCTest
import CoreAudio
@testable import MuteMasterApp

// MARK: - Tone harness (built on the app's own AUHAL + ring buffer)

/// Continuously feeds a phase-continuous sine into a ring so a playback AUHAL can stream it to a
/// device's output stream for as long as we keep filling.
private final class ToneSource {
    let ring: RingBuffer
    private let freq: Double
    private let amp: Float
    private var phase = 0.0
    private var timer: DispatchSourceTimer?

    init(ring: RingBuffer, frequency: Double, amplitude: Float) {
        self.ring = ring
        self.freq = frequency
        self.amp = amplitude
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(3))
        t.setEventHandler { [weak self] in self?.fill() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    private func fill() {
        let ch = Int(EngineFormat.channels)
        let space = ring.capacityFrames - ring.fillFrames
        guard space > 0 else { return }
        let n = Int(min(space, 2048))
        var buf = [Float](repeating: 0, count: n * ch)
        let step = 2.0 * Double.pi * freq / EngineFormat.sampleRate
        for i in 0..<n {
            let s = amp * Float(sin(phase))
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            for c in 0..<ch { buf[i * ch + c] = s }
        }
        ring.write(buf, frameCount: UInt32(n))
    }
}

/// Injects a tone into `deviceID`'s output stream (which the driver loops to its input stream).
private final class ToneInjector {
    private let ring: RingBuffer
    private let source: ToneSource
    private let unit: AUHALUnit

    init(deviceID: AudioObjectID, frequency: Double = 1000, amplitude: Float = 0.5) throws {
        ring = RingBuffer(capacityFrames: 16384, channels: EngineFormat.channels)!
        source = ToneSource(ring: ring, frequency: frequency, amplitude: amplitude)
        unit = try AUHALUnit(mode: .playback, deviceID: deviceID, ring: ring.pointer, mutePtr: nil)
    }
    func start() throws { source.start(); try unit.start() }
    func stop() { unit.stop(); source.stop() }
}

/// Captures a device's input stream into a ring, then drains it for analysis.
private final class ToneRecorder {
    private let ring: RingBuffer
    private let unit: AUHALUnit

    init(deviceID: AudioObjectID) throws {
        ring = RingBuffer(capacityFrames: 65536, channels: EngineFormat.channels)
            ?? { fatalError("ring alloc") }()
        unit = try AUHALUnit(mode: .capture, deviceID: deviceID, ring: ring.pointer, mutePtr: nil)
    }
    func start() throws { try unit.start() }
    func stop() { unit.stop() }

    /// Drain everything captured so far as a mono (channel-0) buffer.
    func drainMono() -> [Float] {
        let ch = Int(EngineFormat.channels)
        let frames = Int(ring.fillFrames)
        guard frames > 0 else { return [] }
        var interleaved = [Float](repeating: 0, count: frames * ch)
        ring.read(into: &interleaved, frameCount: UInt32(frames))
        return ToneDSP.deinterleaveChannel0(interleaved, channels: ch)
    }
}

// MARK: - Tests

final class AudioIntegrationTests: XCTestCase {
    private let toneHz = 1000.0

    private func deviceID(forUID uid: String) throws -> AudioObjectID {
        guard let id = DeviceEnumerator.deviceID(forUID: uid) else {
            throw XCTSkip("Virtual device \(uid) not found — install the driver (Scripts/sign_and_install.sh).")
        }
        return id
    }

    /// M1: audio written to a virtual device's output stream comes back on its input stream.
    func testDriverLoopbackCarriesTone() throws {
        let outID = try deviceID(forUID: ZMIdentifiers.mutableOutputUID)

        let injector = try ToneInjector(deviceID: outID, frequency: toneHz)
        let recorder = try ToneRecorder(deviceID: outID)
        try recorder.start()
        try injector.start()
        Thread.sleep(forTimeInterval: 0.6)
        injector.stop()
        recorder.stop()

        let captured = recorder.drainMono()
        XCTAssertGreaterThan(captured.count, 4096, "expected captured audio from the loopback")
        XCTAssertTrue(ToneDSP.tonePresent(captured, sampleRate: EngineFormat.sampleRate, targetFreq: toneHz),
                      "tone should survive the driver loopback")
    }

    /// M2+M3: real-mic → Mutable Microphone routing carries the tone, and INPUT MUTE silences it.
    /// We stand in for the "real mic" using the Mutable Speaker device as a tone source.
    @MainActor
    func testInputPathRoutesAndMutes() throws {
        let sourceID = try deviceID(forUID: ZMIdentifiers.mutableOutputUID) // plays the "mic" tone
        let micFeedID = try deviceID(forUID: ZMIdentifiers.mutableInputUID) // engine's output device

        // Engine: capture from Mutable Output (our tone), feed into Mutable Input.
        let engine = RoutingEngine()
        engine.configure(realInputUID: ZMIdentifiers.mutableOutputUID, realOutputUID: nil)
        XCTAssertTrue(engine.hasInputPath, "input path should build with both devices present")
        engine.start()
        defer { engine.stop() }

        let injector = try ToneInjector(deviceID: sourceID, frequency: toneHz)
        try injector.start()
        defer { injector.stop() }

        // --- Unmuted: tone should reach the Mutable Input loopback. ---
        engine.setInputMuted(false)
        var recorder = try ToneRecorder(deviceID: micFeedID)
        try recorder.start()
        Thread.sleep(forTimeInterval: 0.7)
        recorder.stop()
        let unmuted = recorder.drainMono()
        XCTAssertTrue(ToneDSP.tonePresent(unmuted, sampleRate: EngineFormat.sampleRate, targetFreq: toneHz),
                      "unmuted input path should carry the tone")

        // --- Muted: tone should be gone. ---
        engine.setInputMuted(true)
        Thread.sleep(forTimeInterval: 0.2) // let the mute take effect / flush
        recorder = try ToneRecorder(deviceID: micFeedID)
        try recorder.start()
        Thread.sleep(forTimeInterval: 0.7)
        recorder.stop()
        let muted = recorder.drainMono()
        XCTAssertFalse(ToneDSP.tonePresent(muted, sampleRate: EngineFormat.sampleRate, targetFreq: toneHz),
                       "muted input path should be silent")
    }
}
