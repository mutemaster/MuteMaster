//
//  ToneDSPTests.swift
//  Pure-DSP unit tests. No audio hardware, no driver — these run anywhere, including CI.
//  They validate the tone generator + Goertzel detector that the integration tests rely on.
//

import XCTest
@testable import MuteMasterApp

final class ToneDSPTests: XCTestCase {
    let sampleRate = 48_000.0
    let frames = 4096

    func testDetectsToneAtItsFrequency() {
        let tone = ToneDSP.sine(frequency: 1000, sampleRate: sampleRate, frameCount: frames, amplitude: 0.5)
        XCTAssertTrue(ToneDSP.tonePresent(tone, sampleRate: sampleRate, targetFreq: 1000))
    }

    func testRejectsSilence() {
        let silence = [Float](repeating: 0, count: frames)
        XCTAssertFalse(ToneDSP.tonePresent(silence, sampleRate: sampleRate, targetFreq: 1000))
    }

    func testRejectsWrongFrequency() {
        let tone = ToneDSP.sine(frequency: 3000, sampleRate: sampleRate, frameCount: frames, amplitude: 0.5)
        XCTAssertFalse(ToneDSP.tonePresent(tone, sampleRate: sampleRate, targetFreq: 1000))
    }

    func testMagnitudeTracksAmplitude() {
        let quiet = ToneDSP.sine(frequency: 1000, sampleRate: sampleRate, frameCount: frames, amplitude: 0.1)
        let loud  = ToneDSP.sine(frequency: 1000, sampleRate: sampleRate, frameCount: frames, amplitude: 0.5)
        let mQuiet = ToneDSP.goertzelMagnitude(quiet, sampleRate: sampleRate, targetFreq: 1000)
        let mLoud  = ToneDSP.goertzelMagnitude(loud,  sampleRate: sampleRate, targetFreq: 1000)
        XCTAssertGreaterThan(mLoud, mQuiet * 3)   // ~5x louder
    }

    func testInterleaveRoundTrip() {
        let mono = ToneDSP.sine(frequency: 1000, sampleRate: sampleRate, frameCount: 128, amplitude: 0.4)
        let stereo = ToneDSP.interleave(mono, channels: 2)
        XCTAssertEqual(stereo.count, mono.count * 2)
        let back = ToneDSP.deinterleaveChannel0(stereo, channels: 2)
        XCTAssertEqual(back, mono)
    }
}
