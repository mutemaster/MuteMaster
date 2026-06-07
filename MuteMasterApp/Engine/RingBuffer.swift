//
//  RingBuffer.swift
//  A small Swift wrapper around the C ZMRingBuffer so the rest of the app (and the tests) can use
//  it with value semantics for ownership while still handing the raw pointer to the real-time
//  audio callbacks.
//

import Foundation

final class RingBuffer {
    /// Raw pointer handed to the RT callbacks (which call zm_ring_read / zm_ring_write directly).
    let pointer: OpaquePointer
    let channels: UInt32

    init?(capacityFrames: UInt32, channels: UInt32) {
        guard let p = zm_ring_create(capacityFrames, channels) else { return nil }
        self.pointer = p
        self.channels = channels
    }

    deinit { zm_ring_destroy(pointer) }

    @discardableResult
    func write(_ samples: [Float], frameCount: UInt32) -> UInt32 {
        samples.withUnsafeBufferPointer { zm_ring_write(pointer, $0.baseAddress, frameCount) }
    }

    /// Read up to `frameCount` frames; returns the number of REAL frames read (shortfall is silence).
    @discardableResult
    func read(into out: inout [Float], frameCount: UInt32) -> UInt32 {
        out.withUnsafeMutableBufferPointer { zm_ring_read(pointer, $0.baseAddress, frameCount) }
    }

    var fillFrames: UInt32 { zm_ring_fill_frames(pointer) }
    var capacityFrames: UInt32 { zm_ring_capacity_frames(pointer) }
    func reset() { zm_ring_reset(pointer) }
}
