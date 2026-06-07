//
//  DeviceEnumerator.swift
//  Lists Core Audio devices and resolves between a device's stable UID (what we persist) and its
//  ephemeral AudioObjectID (what the audio APIs need). AudioObjectIDs are reassigned across reboots
//  and reconnects, so we ALWAYS store UIDs and re-resolve to IDs at runtime.
//

import Foundation
import CoreAudio

/// A discovered audio device.
struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID      // ephemeral — valid only this session
    let uid: String            // stable — safe to persist
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum DeviceEnumerator {

    /// All devices currently known to Core Audio.
    static func allDevices() -> [AudioDeviceInfo] {
        let deviceIDs = systemDeviceIDs()
        return deviceIDs.compactMap { info(for: $0) }
    }

    /// Devices that can be used as an input (capture) source.
    static func inputDevices() -> [AudioDeviceInfo] { allDevices().filter { $0.hasInput } }

    /// Devices that can be used as an output (playback) destination.
    static func outputDevices() -> [AudioDeviceInfo] { allDevices().filter { $0.hasOutput } }

    /// Resolve a persisted UID back to a live AudioObjectID, or nil if not currently present.
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDevices().first { $0.uid == uid }?.id
    }

    // MARK: - Core Audio property plumbing

    private static func systemDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &dataSize, &ids)
        return status == noErr ? ids : []
    }

    private static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: name,
            hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
            hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0)
    }

    private static func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (value as String) : nil
    }

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufList) == noErr else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(bufList.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for buffer in abl { channels += Int(buffer.mNumberChannels) }
        return channels
    }
}
