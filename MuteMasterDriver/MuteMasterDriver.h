//
//  MuteMasterDriver.h
//  MuteMasterDriver — a Core Audio AudioServerPlugIn (userspace HAL driver).
//
//  This driver publishes TWO virtual audio devices:
//      • "Mutable Microphone"  (UID: MuteMasterInput)   — Zoom etc. select this as their MIC.
//      • "Mutable Speaker" (UID: MuteMasterOutput)  — Zoom etc. select this as their SPEAKER.
//
//  Both devices are structurally IDENTICAL full-duplex "loopback" devices: anything written to
//  a device's OUTPUT stream is copied (via a ring buffer) into that same device's INPUT stream,
//  so another process/app reading the input stream hears what was written to the output stream.
//
//  How the companion app uses them:
//      Input path : app captures the REAL mic  → writes to "Mutable Microphone".OUTPUT
//                   → driver loops it to        → "Mutable Microphone".INPUT  → Zoom reads it.
//      Output path: Zoom writes to "Mutable Speaker".OUTPUT
//                   → driver loops it to        → "Mutable Speaker".INPUT → app reads it
//                   → app plays it to the REAL speakers.
//
//  MUTE lives in the companion app's routing engine, NOT here. This driver is a plain loopback.
//
//  Architecture is modeled on Apple's "NullAudio" AudioServerPlugIn sample (object-ID dispatch,
//  zero-timestamp clock) with the loopback ring-buffer idea from ExistentialAudio/BlackHole.
//

#ifndef MuteMasterDriver_h
#define MuteMasterDriver_h

#include <CoreAudio/AudioServerPlugIn.h>

#pragma mark - Identity constants

// Bundle identifier of this plug-in (must match Info.plist CFBundleIdentifier).
#define kPlugIn_BundleID            "app.mutemaster.driver"

// Stable, user-visible device UIDs. The companion app finds the devices by these UIDs.
#define kDevice_Mic_UID             "MuteMasterInput"
#define kDevice_Spk_UID             "MuteMasterOutput"

#define kDevice_Mic_Name            "Mutable Microphone"
#define kDevice_Spk_Name            "Mutable Speaker"

// Model UID is shared by both devices (same hardware "model").
#define kDevice_ModelUID            "MuteMasterModel"
#define kManufacturer_Name          "MuteMaster"

#pragma mark - Object IDs
//
// Core Audio identifies every object (plug-in, device, stream, control) by an AudioObjectID.
// We use a fixed, hard-coded numbering scheme (like NullAudio) because our object graph is static.
//
enum {
    kObjectID_PlugIn                 = kAudioObjectPlugInObject, // always 1

    // Device 0 — "Mutable Microphone"
    kObjectID_Device_Mic            = 2,
    kObjectID_Stream_Mic_Input      = 3,   // the stream Zoom READS (the loopback result)
    kObjectID_Stream_Mic_Output     = 4,   // the stream our app WRITES (real mic audio)

    // Device 1 — "Mutable Speaker"
    kObjectID_Device_Spk            = 5,
    kObjectID_Stream_Spk_Input      = 6,   // the stream our app READS (the loopback result)
    kObjectID_Stream_Spk_Output     = 7    // the stream Zoom WRITES (call audio)
};

#define kNumberOfDevices            2

#pragma mark - Audio format

// Both devices use a fixed format. The companion app's engine does any sample-rate conversion
// to/from the real hardware, so the driver itself stays simple and glitch-free.
#define kSampleRate_Default         48000.0
#define kChannelsPerFrame           2
#define kBitsPerChannel             32                              // Float32
#define kBytesPerFrame              (kChannelsPerFrame * sizeof(Float32))

// Size of each device's loopback ring buffer, in frames. Must be a power of two for cheap
// wrap-around masking. ~0.34 s at 48 kHz — generous headroom for scheduling jitter.
#define kRingBufferFrames           16384

#endif /* MuteMasterDriver_h */
