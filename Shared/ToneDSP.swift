//
//  ToneDSP.swift
//  Shared between the app and the test target.
//
//  Tiny, dependency-free DSP used by the integration tests: a sine-tone generator and a
//  Goertzel detector that answers "is frequency F present in this buffer?". The Goertzel
//  algorithm is a cheap way to measure the energy at a single frequency without a full FFT.
//

import Foundation

public enum ToneDSP {

    /// Generate `frameCount` mono samples of a sine wave.
    /// - Parameters:
    ///   - frequency: tone frequency in Hz (e.g. 1000).
    ///   - sampleRate: samples per second (e.g. 48000).
    ///   - amplitude: peak amplitude in [0, 1].
    public static func sine(frequency: Double,
                            sampleRate: Double,
                            frameCount: Int,
                            amplitude: Float = 0.5) -> [Float] {
        var out = [Float](repeating: 0, count: frameCount)
        let step = 2.0 * Double.pi * frequency / sampleRate
        var phase = 0.0
        for i in 0..<frameCount {
            out[i] = amplitude * Float(sin(phase))
            phase += step
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }
        return out
    }

    /// Interleave a mono buffer into `channels` identical channels.
    public static func interleave(_ mono: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return mono }
        var out = [Float](repeating: 0, count: mono.count * channels)
        for i in 0..<mono.count {
            let base = i * channels
            for c in 0..<channels { out[base + c] = mono[i] }
        }
        return out
    }

    /// Take channel 0 out of an interleaved buffer.
    public static func deinterleaveChannel0(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = interleaved[i * channels] }
        return out
    }

    /// Normalized magnitude (≈ peak amplitude) of `targetFreq` within `samples`, via Goertzel.
    public static func goertzelMagnitude(_ samples: [Float],
                                         sampleRate: Double,
                                         targetFreq: Double) -> Double {
        let n = samples.count
        guard n > 0 else { return 0 }
        let k = Int(0.5 + Double(n) * targetFreq / sampleRate)
        let omega = 2.0 * Double.pi * Double(k) / Double(n)
        let cosine = cos(omega)
        let sine = sin(omega)
        let coeff = 2.0 * cosine
        var q1 = 0.0, q2 = 0.0
        for s in samples {
            let q0 = coeff * q1 - q2 + Double(s)
            q2 = q1
            q1 = q0
        }
        let real = q1 - q2 * cosine
        let imag = q2 * sine
        // Divide by n/2 so a full-scale sine reads ≈ its amplitude.
        return sqrt(real * real + imag * imag) / (Double(n) / 2.0)
    }

    /// RMS level of a buffer (used to distinguish "real signal" from "near silence").
    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        return sqrt(sum / Double(samples.count))
    }

    /// Decision used by the integration tests: is `targetFreq` clearly present?
    /// Requires both an absolute magnitude floor and that the tone dominates total energy.
    public static func tonePresent(_ samples: [Float],
                                   sampleRate: Double,
                                   targetFreq: Double,
                                   magnitudeFloor: Double = 0.02) -> Bool {
        let mag = goertzelMagnitude(samples, sampleRate: sampleRate, targetFreq: targetFreq)
        let level = rms(samples)
        // A pure sine of amplitude A has RMS ≈ A/√2, so mag ≈ √2 * rms when the tone dominates.
        let dominates = level > 0 && (mag / (level * 1.4142135623730951)) > 0.5
        return mag > magnitudeFloor && dominates
    }
}
