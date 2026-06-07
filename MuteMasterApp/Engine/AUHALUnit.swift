//
//  AUHALUnit.swift
//  A thin wrapper around one AUHAL audio unit (kAudioUnitSubType_HALOutput) bound to a specific
//  device, in either CAPTURE or PLAYBACK mode.
//
//  AVAudioEngine can only use ONE device for both input and output, so to move audio between two
//  different devices we drive the AUHAL directly: a capture unit on device A and a playback unit
//  on device B, connected by a lock-free ring buffer (ZMRingBuffer).
//
//  The real-time render/input callbacks are @convention(c) free functions. They must not allocate
//  or touch Swift objects (no ARC on the audio thread), so everything they need is packed into a
//  plain-old-data RTContext passed as the callback refCon.
//

import Foundation
import AudioToolbox
import CoreAudio

/// The single audio format used throughout the engine: 48 kHz, stereo, interleaved Float32.
/// AUHAL transparently sample-rate-converts between this and each device's native rate, so the
/// only thing left for us to manage is clock drift between the two independent devices.
enum EngineFormat {
    static let sampleRate: Double = 48_000
    static let channels: UInt32 = 2
    static let maxFramesPerSlice: UInt32 = 4096

    static func asbd() -> AudioStreamBasicDescription {
        let bytesPerFrame = channels * UInt32(MemoryLayout<Float>.size)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }
}

/// Plain-old-data shared with the real-time callbacks. No Swift references here.
struct RTContext {
    var audioUnit: AudioUnit?
    var ring: OpaquePointer?                  // ZMRingBuffer*
    var scratch: UnsafeMutablePointer<Float>? // capture-only render target
    var channels: UInt32 = 0
    var mute: UnsafeMutablePointer<Int32>?    // playback-only; non-zero ⇒ output silence
}

enum AUHALMode { case capture, playback }

final class AUHALUnit {
    private var unit: AudioUnit?
    private let mode: AUHALMode
    private let ctx: UnsafeMutablePointer<RTContext>
    private var scratch: UnsafeMutablePointer<Float>?
    private(set) var isRunning = false

    /// - Parameters:
    ///   - mode: capture (device → ring) or playback (ring → device).
    ///   - deviceID: the Core Audio device to bind to.
    ///   - ring: the shared ring buffer (producer for capture, consumer for playback).
    ///   - mutePtr: playback-only pointer to the path's mute flag.
    init(mode: AUHALMode, deviceID: AudioObjectID, ring: OpaquePointer, mutePtr: UnsafeMutablePointer<Int32>?) throws {
        self.mode = mode
        self.ctx = UnsafeMutablePointer<RTContext>.allocate(capacity: 1)
        self.ctx.initialize(to: RTContext())

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EngineError.componentNotFound }

        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "AudioComponentInstanceNew")
        guard let audioUnit = au else { throw EngineError.componentNotFound }
        self.unit = audioUnit

        var enable: UInt32 = 1
        var disable: UInt32 = 0

        if mode == .capture {
            // Enable input (element 1), disable output (element 0).
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)), "EnableIO input")
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)), "DisableIO output")
        } else {
            // Enable output (element 0), disable input (element 1).
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)), "EnableIO output")
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size)), "DisableIO input")
        }

        // Bind to the chosen device. Must be done AFTER EnableIO.
        var dev = deviceID
        try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size)), "CurrentDevice")

        // Set our client format (48k stereo float) on the side that faces us.
        var fmt = EngineFormat.asbd()
        if mode == .capture {
            try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "StreamFormat (capture out)")
        } else {
            try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "StreamFormat (playback in)")
        }

        var maxFrames = EngineFormat.maxFramesPerSlice
        try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "MaxFramesPerSlice")

        // Fill the RT context.
        ctx.pointee.audioUnit = audioUnit
        ctx.pointee.ring = ring
        ctx.pointee.channels = EngineFormat.channels
        ctx.pointee.mute = mutePtr

        if mode == .capture {
            let cap = Int(EngineFormat.maxFramesPerSlice) * Int(EngineFormat.channels)
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            scratch!.initialize(repeating: 0, count: cap)
            ctx.pointee.scratch = scratch

            var cb = AURenderCallbackStruct(inputProc: captureCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx))
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetInputCallback")
        } else {
            var cb = AURenderCallbackStruct(inputProc: renderCallback, inputProcRefCon: UnsafeMutableRawPointer(ctx))
            try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "SetRenderCallback")
        }

        try check(AudioUnitInitialize(audioUnit), "AudioUnitInitialize")
    }

    func start() throws {
        guard let unit, !isRunning else { return }
        try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart")
        isRunning = true
    }

    func stop() {
        guard let unit, isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        scratch?.deallocate()
        ctx.deinitialize(count: 1)
        ctx.deallocate()
    }
}

// MARK: - Real-time callbacks (no allocation, no ARC)

private func captureCallback(_ refCon: UnsafeMutableRawPointer,
                             _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                             _ inBusNumber: UInt32,
                             _ inNumberFrames: UInt32,
                             _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let ctx = refCon.assumingMemoryBound(to: RTContext.self).pointee
    guard let au = ctx.audioUnit, let scratch = ctx.scratch, let ring = ctx.ring else { return noErr }

    // Render the captured audio into our scratch buffer (interleaved, 1 buffer).
    var abl = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: ctx.channels,
            mDataByteSize: inNumberFrames * ctx.channels * UInt32(MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(scratch)))
    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &abl)
    if status == noErr {
        _ = zm_ring_write(ring, scratch, inNumberFrames)
    }
    return status
}

private func renderCallback(_ refCon: UnsafeMutableRawPointer,
                            _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            _ inBusNumber: UInt32,
                            _ inNumberFrames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let ctx = refCon.assumingMemoryBound(to: RTContext.self).pointee
    guard let ioData, let ring = ctx.ring else { return noErr }
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard let mData = abl[0].mData else { return noErr }
    let out = mData.assumingMemoryBound(to: Float.self)

    // Pull audio from the ring (underrun is zero-filled inside zm_ring_read).
    _ = zm_ring_read(ring, out, inNumberFrames)

    // Engine-side MUTE: if muted, overwrite with silence. Single source of truth for mute.
    if let mute = ctx.mute, mute.pointee != 0 {
        memset(mData, 0, Int(abl[0].mDataByteSize))
    }
    return noErr
}

// MARK: - Errors

enum EngineError: Error, CustomStringConvertible {
    case componentNotFound
    case osStatus(String, OSStatus)
    case deviceNotFound(String)

    var description: String {
        switch self {
        case .componentNotFound: return "AUHAL audio component not found"
        case .osStatus(let what, let code): return "\(what) failed (OSStatus \(code))"
        case .deviceNotFound(let uid): return "Audio device not found for UID \(uid)"
        }
    }
}

@inline(__always) private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw EngineError.osStatus(what, status) }
}
