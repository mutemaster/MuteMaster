//
//  MuteMasterDriver.c
//  MuteMasterDriver
//
//  A Core Audio AudioServerPlugIn that publishes two full-duplex loopback devices.
//  See MuteMasterDriver.h for the high-level design.
//
//  Code map:
//    • Factory + COM plumbing ............ MuteMaster_Create / QueryInterface / AddRef / Release
//    • Object-graph state ................ gDevices[], DeviceState, lookup helpers
//    • Property dispatch ................. HasProperty / IsPropertySettable / GetPropertyDataSize /
//                                          GetPropertyData / SetPropertyData  (split per object class)
//    • IO / clock ....................... StartIO / StopIO / GetZeroTimeStamp / *IOOperation
//

#include "MuteMasterDriver.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#pragma mark - State

// One of these per virtual device. Both devices are identical loopback devices; only their
// names/UIDs and stream terminal types differ.
typedef struct {
    AudioObjectID   deviceID;
    AudioObjectID   inputStreamID;     // stream other apps READ  (loopback result)
    AudioObjectID   outputStreamID;    // stream other apps WRITE (source audio)
    const char*     uid;
    const char*     name;
    UInt32          inputTerminalType;
    UInt32          outputTerminalType;

    Float64         sampleRate;

    // IO bookkeeping (guarded by gStateMutex for start/stop transitions).
    UInt64          ioRunningCount;    // number of clients that have called StartIO

    // Zero-timestamp clock (see GetZeroTimeStamp).
    UInt64          anchorHostTime;
    volatile Float64 numberTimeStamps;

    // Loopback ring: interleaved Float32, kRingBufferFrames * kChannelsPerFrame samples.
    Float32*        ring;
} DeviceState;

static DeviceState gDevices[kNumberOfDevices];

// Host clock conversion (mach ticks per audio frame), computed in Initialize.
static Float64 gHostTicksPerFrame = 0.0;

// The host object lets us notify Core Audio when properties change.
static AudioServerPlugInHostRef gPlugInHost = NULL;

// Guards object-graph state changes (IO start/stop, sample-rate changes). The real-time IO
// copy path does NOT take this lock; it relies on single-producer/single-consumer ring access.
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;

#pragma mark - Lookup helpers

static DeviceState* DeviceForID(AudioObjectID inID)
{
    for (int i = 0; i < kNumberOfDevices; ++i) {
        if (gDevices[i].deviceID == inID) { return &gDevices[i]; }
    }
    return NULL;
}

// Returns the owning device for a stream object ID, and whether the stream is the input stream.
static DeviceState* DeviceForStream(AudioObjectID inID, bool* outIsInput)
{
    for (int i = 0; i < kNumberOfDevices; ++i) {
        if (gDevices[i].inputStreamID == inID)  { if (outIsInput) *outIsInput = true;  return &gDevices[i]; }
        if (gDevices[i].outputStreamID == inID) { if (outIsInput) *outIsInput = false; return &gDevices[i]; }
    }
    return NULL;
}

static bool IsDeviceID(AudioObjectID inID) { return DeviceForID(inID) != NULL; }
static bool IsStreamID(AudioObjectID inID) { return DeviceForStream(inID, NULL) != NULL; }

// Fill a standard 2-channel Float32 interleaved format at the given sample rate.
static void FillASBD(AudioStreamBasicDescription* f, Float64 sr)
{
    f->mSampleRate       = sr;
    f->mFormatID         = kAudioFormatLinearPCM;
    f->mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket   = kBytesPerFrame;
    f->mFramesPerPacket  = 1;
    f->mBytesPerFrame    = kBytesPerFrame;
    f->mChannelsPerFrame = kChannelsPerFrame;
    f->mBitsPerChannel   = kBitsPerChannel;
    f->mReserved         = 0;
}

#pragma mark - Forward declarations (COM + interface)

static HRESULT  MuteMaster_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    MuteMaster_AddRef(void* inDriver);
static ULONG    MuteMaster_Release(void* inDriver);
static OSStatus MuteMaster_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus MuteMaster_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus MuteMaster_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus MuteMaster_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MuteMaster_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MuteMaster_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus MuteMaster_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  MuteMaster_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus MuteMaster_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus MuteMaster_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus MuteMaster_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus MuteMaster_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus MuteMaster_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MuteMaster_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MuteMaster_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus MuteMaster_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus MuteMaster_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus MuteMaster_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus MuteMaster_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

#pragma mark - The interface vtable

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    MuteMaster_QueryInterface,
    MuteMaster_AddRef,
    MuteMaster_Release,
    MuteMaster_Initialize,
    MuteMaster_CreateDevice,
    MuteMaster_DestroyDevice,
    MuteMaster_AddDeviceClient,
    MuteMaster_RemoveDeviceClient,
    MuteMaster_PerformDeviceConfigurationChange,
    MuteMaster_AbortDeviceConfigurationChange,
    MuteMaster_HasProperty,
    MuteMaster_IsPropertySettable,
    MuteMaster_GetPropertyDataSize,
    MuteMaster_GetPropertyData,
    MuteMaster_SetPropertyData,
    MuteMaster_StartIO,
    MuteMaster_StopIO,
    MuteMaster_GetZeroTimeStamp,
    MuteMaster_WillDoIOOperation,
    MuteMaster_BeginIOOperation,
    MuteMaster_DoIOOperation,
    MuteMaster_EndIOOperation
};

static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef        gDriverRef    = &gInterfacePtr;
static UInt32                            gRefCount     = 1;

#pragma mark - Factory (entry point named in Info.plist CFPlugInFactories)

void* MuteMaster_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* MuteMaster_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

#pragma mark - COM

static HRESULT MuteMaster_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) { return kAudioHardwareIllegalOperationError; }

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        ++gRefCount;
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG MuteMaster_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) { return 0; }
    if (gRefCount < UINT32_MAX) { ++gRefCount; }
    return gRefCount;
}

static ULONG MuteMaster_Release(void* inDriver)
{
    if (inDriver != gDriverRef) { return 0; }
    if (gRefCount > 0) { --gRefCount; }
    return gRefCount;
}

#pragma mark - Initialize / lifecycle

static OSStatus MuteMaster_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    gPlugInHost = inHost;

    // Convert mach time units to a host-tick-per-frame ratio for our software clock.
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9;
    gHostTicksPerFrame = hostTicksPerSecond / kSampleRate_Default;

    // Configure the two devices.
    memset(gDevices, 0, sizeof(gDevices));

    gDevices[0].deviceID          = kObjectID_Device_Mic;
    gDevices[0].inputStreamID     = kObjectID_Stream_Mic_Input;
    gDevices[0].outputStreamID    = kObjectID_Stream_Mic_Output;
    gDevices[0].uid               = kDevice_Mic_UID;
    gDevices[0].name              = kDevice_Mic_Name;
    gDevices[0].inputTerminalType = kAudioStreamTerminalTypeMicrophone;
    gDevices[0].outputTerminalType= kAudioStreamTerminalTypeSpeaker;

    gDevices[1].deviceID          = kObjectID_Device_Spk;
    gDevices[1].inputStreamID     = kObjectID_Stream_Spk_Input;
    gDevices[1].outputStreamID    = kObjectID_Stream_Spk_Output;
    gDevices[1].uid               = kDevice_Spk_UID;
    gDevices[1].name              = kDevice_Spk_Name;
    gDevices[1].inputTerminalType = kAudioStreamTerminalTypeMicrophone;
    gDevices[1].outputTerminalType= kAudioStreamTerminalTypeSpeaker;

    for (int i = 0; i < kNumberOfDevices; ++i) {
        gDevices[i].sampleRate     = kSampleRate_Default;
        gDevices[i].ioRunningCount = 0;
        gDevices[i].ring = (Float32*)calloc((size_t)kRingBufferFrames * kChannelsPerFrame, sizeof(Float32));
        if (gDevices[i].ring == NULL) { return kAudioHardwareUnspecifiedError; }
    }
    return noErr;
}

// We publish a fixed set of devices, so dynamic creation/destruction is unsupported.
static OSStatus MuteMaster_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MuteMaster_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MuteMaster_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus MuteMaster_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return noErr;
}

static OSStatus MuteMaster_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

static OSStatus MuteMaster_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return noErr;
}

#pragma mark - Property helpers

// Returns true if the selector is one the given device object answers.
static bool DeviceHasProperty(AudioObjectPropertySelector sel)
{
    switch (sel) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        default:
            return false;
    }
}

static bool StreamHasProperty(AudioObjectPropertySelector sel)
{
    switch (sel) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static bool PlugInHasProperty(AudioObjectPropertySelector sel)
{
    switch (sel) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

#pragma mark - HasProperty / IsPropertySettable

static Boolean MuteMaster_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL) { return false; }

    if (inObjectID == kObjectID_PlugIn)  { return PlugInHasProperty(inAddress->mSelector); }
    if (IsDeviceID(inObjectID))          { return DeviceHasProperty(inAddress->mSelector); }
    if (IsStreamID(inObjectID))          { return StreamHasProperty(inAddress->mSelector); }
    return false;
}

static OSStatus MuteMaster_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outIsSettable == NULL) { return kAudioHardwareIllegalOperationError; }

    *outIsSettable = false;
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return noErr;
}

#pragma mark - GetPropertyDataSize

static OSStatus MuteMaster_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || outDataSize == NULL) { return kAudioHardwareIllegalOperationError; }

    // PlugIn object
    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:           *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:  *outDataSize = sizeof(CFStringRef);  return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:      *outDataSize = kNumberOfDevices * sizeof(AudioObjectID); return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice: *outDataSize = sizeof(AudioObjectID); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    // Device objects
    if (IsDeviceID(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:                 *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:              *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:   *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate:     *outDataSize = sizeof(Float64); return noErr;
            case kAudioObjectPropertyOwnedObjects:          *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyControlList:           *outDataSize = 0; return noErr;
            case kAudioDevicePropertyRelatedDevices:        *outDataSize = 1 * sizeof(AudioObjectID); return noErr;
            case kAudioDevicePropertyStreams: {
                UInt32 n = 2;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput)  { n = 1; }
                if (inAddress->mScope == kAudioObjectPropertyScopeOutput) { n = 1; }
                *outDataSize = n * sizeof(AudioObjectID); return noErr;
            }
            case kAudioDevicePropertyAvailableNominalSampleRates: *outDataSize = sizeof(AudioValueRange); return noErr;
            case kAudioDevicePropertyPreferredChannelsForStereo:  *outDataSize = 2 * sizeof(UInt32); return noErr;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelsPerFrame * sizeof(AudioChannelDescription));
                return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    // Stream objects
    if (IsStreamID(inObjectID)) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:                  *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:                *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:         *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

#pragma mark - GetPropertyData

static OSStatus MuteMaster_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inDriver; (void)inClientProcessID;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) { return kAudioHardwareIllegalOperationError; }

    // ---- PlugIn object ----
    if (inObjectID == kObjectID_PlugIn) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kManufacturer_Name); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioPlugInPropertyResourceBundle:
                *((CFStringRef*)outData) = CFSTR(""); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                UInt32 capacity = inDataSize / sizeof(AudioObjectID);
                UInt32 n = 0;
                for (int i = 0; i < kNumberOfDevices && n < capacity; ++i) { ids[n++] = gDevices[i].deviceID; }
                *outDataSize = n * sizeof(AudioObjectID); return noErr;
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) { return kAudioHardwareIllegalOperationError; }
                CFStringRef uid = *((CFStringRef*)inQualifierData);
                AudioObjectID found = kAudioObjectUnknown;
                for (int i = 0; i < kNumberOfDevices; ++i) {
                    CFStringRef devUID = CFStringCreateWithCString(NULL, gDevices[i].uid, kCFStringEncodingUTF8);
                    if (devUID && CFEqual(uid, devUID)) { found = gDevices[i].deviceID; }
                    if (devUID) CFRelease(devUID);
                }
                *((AudioObjectID*)outData) = found; *outDataSize = sizeof(AudioObjectID); return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    // ---- Device objects ----
    DeviceState* dev = DeviceForID(inObjectID);
    if (dev != NULL) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioObjectPropertyName:
                *((CFStringRef*)outData) = CFStringCreateWithCString(NULL, dev->name, kCFStringEncodingUTF8); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioObjectPropertyManufacturer:
                *((CFStringRef*)outData) = CFSTR(kManufacturer_Name); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyDeviceUID:
                *((CFStringRef*)outData) = CFStringCreateWithCString(NULL, dev->uid, kCFStringEncodingUTF8); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyModelUID:
                *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID); *outDataSize = sizeof(CFStringRef); return noErr;
            case kAudioDevicePropertyTransportType:
                *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyClockDomain:
                *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsAlive:
                *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceIsRunning:
                *((UInt32*)outData) = (dev->ioRunningCount > 0) ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyIsHidden:
                *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *((UInt32*)outData) = kRingBufferFrames; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioDevicePropertyNominalSampleRate:
                *((Float64*)outData) = dev->sampleRate; *outDataSize = sizeof(Float64); return noErr;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0; return noErr;
            case kAudioDevicePropertyRelatedDevices: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                ids[0] = dev->deviceID; *outDataSize = sizeof(AudioObjectID); return noErr;
            }
            case kAudioObjectPropertyOwnedObjects: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                UInt32 capacity = inDataSize / sizeof(AudioObjectID);
                UInt32 n = 0;
                if (n < capacity) ids[n++] = dev->inputStreamID;
                if (n < capacity) ids[n++] = dev->outputStreamID;
                *outDataSize = n * sizeof(AudioObjectID); return noErr;
            }
            case kAudioDevicePropertyStreams: {
                AudioObjectID* ids = (AudioObjectID*)outData;
                UInt32 capacity = inDataSize / sizeof(AudioObjectID);
                UInt32 n = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    if (n < capacity) ids[n++] = dev->inputStreamID;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    if (n < capacity) ids[n++] = dev->outputStreamID;
                } else {
                    if (n < capacity) ids[n++] = dev->inputStreamID;
                    if (n < capacity) ids[n++] = dev->outputStreamID;
                }
                *outDataSize = n * sizeof(AudioObjectID); return noErr;
            }
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange* r = (AudioValueRange*)outData;
                r[0].mMinimum = kSampleRate_Default;
                r[0].mMaximum = kSampleRate_Default;
                *outDataSize = sizeof(AudioValueRange); return noErr;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32* ch = (UInt32*)outData;
                ch[0] = 1; ch[1] = 2; *outDataSize = 2 * sizeof(UInt32); return noErr;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                AudioChannelLayout* layout = (AudioChannelLayout*)outData;
                UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelsPerFrame * sizeof(AudioChannelDescription)));
                memset(layout, 0, size);
                layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                layout->mNumberChannelDescriptions = kChannelsPerFrame;
                layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                *outDataSize = size; return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    // ---- Stream objects ----
    bool isInput = false;
    DeviceState* sdev = DeviceForStream(inObjectID, &isInput);
    if (sdev != NULL) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyBaseClass:
                *((AudioClassID*)outData) = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyClass:
                *((AudioClassID*)outData) = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return noErr;
            case kAudioObjectPropertyOwner:
                *((AudioObjectID*)outData) = sdev->deviceID; *outDataSize = sizeof(AudioObjectID); return noErr;
            case kAudioStreamPropertyIsActive:
                *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyDirection:
                *((UInt32*)outData) = isInput ? 1 : 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyTerminalType:
                *((UInt32*)outData) = isInput ? sdev->inputTerminalType : sdev->outputTerminalType; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyStartingChannel:
                *((UInt32*)outData) = 1; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyLatency:
                *((UInt32*)outData) = 0; *outDataSize = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                FillASBD((AudioStreamBasicDescription*)outData, sdev->sampleRate);
                *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription* rd = (AudioStreamRangedDescription*)outData;
                FillASBD(&rd[0].mFormat, kSampleRate_Default);
                rd[0].mSampleRateRange.mMinimum = kSampleRate_Default;
                rd[0].mSampleRateRange.mMaximum = kSampleRate_Default;
                *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

#pragma mark - SetPropertyData

static OSStatus MuteMaster_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inAddress == NULL || inData == NULL) { return kAudioHardwareIllegalOperationError; }

    // We expose only a single fixed sample rate / format, so "setting" them just validates the
    // request matches what we already provide. This satisfies the HAL handshake without change.
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate: {
            if (inDataSize != sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
            Float64 requested = *((const Float64*)inData);
            return (requested == kSampleRate_Default) ? noErr : kAudioHardwareIllegalOperationError;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (inDataSize != sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
            const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
            if (f->mSampleRate == kSampleRate_Default && f->mChannelsPerFrame == kChannelsPerFrame &&
                f->mFormatID == kAudioFormatLinearPCM) {
                return noErr;
            }
            return kAudioHardwareIllegalOperationError;
        }
        case kAudioStreamPropertyIsActive:
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - IO start/stop

static OSStatus MuteMaster_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if (dev->ioRunningCount == 0) {
        // First client: anchor the software clock and clear the ring.
        dev->anchorHostTime   = mach_absolute_time();
        dev->numberTimeStamps = 0.0;
        memset(dev->ring, 0, (size_t)kRingBufferFrames * kChannelsPerFrame * sizeof(Float32));
    }
    dev->ioRunningCount += 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus MuteMaster_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    if (dev->ioRunningCount > 0) { dev->ioRunningCount -= 1; }
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

#pragma mark - Zero timestamp (software clock)

// Reports the most recent ring-buffer boundary as a (sampleTime, hostTime) pair. The HAL uses
// this to relate its own host-time scheduling to our device's running sample count. Modeled on
// Apple's NullAudio sample.
static OSStatus MuteMaster_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    DeviceState* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL || outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingBufferFrames;
    // Host time at which the NEXT period would begin.
    Float64 nextOffset = (dev->numberTimeStamps + 1.0) * ticksPerPeriod;
    UInt64 nextHostTime = dev->anchorHostTime + (UInt64)nextOffset;
    if (now >= nextHostTime) {
        dev->numberTimeStamps += 1.0;
    }
    *outSampleTime = dev->numberTimeStamps * (Float64)kRingBufferFrames;
    *outHostTime   = dev->anchorHostTime + (UInt64)(dev->numberTimeStamps * ticksPerPeriod);
    *outSeed       = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

#pragma mark - IO operations (the loopback copy)

static OSStatus MuteMaster_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    Boolean willDo = false, inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true; inPlace = true; break;
        default:
            willDo = false; inPlace = true; break;
    }
    if (outWillDo)        { *outWillDo = willDo; }
    if (outWillDoInPlace) { *outWillDoInPlace = inPlace; }
    return noErr;
}

static OSStatus MuteMaster_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

// Copy `frames` of audio between a client buffer and the device ring, handling wrap-around.
// direction: true = ring -> client (ReadInput); false = client -> ring (WriteMix).
static void RingCopy(DeviceState* dev, Float64 sampleTime, UInt32 frames, void* clientBuffer, bool ringToClient)
{
    if (dev->ring == NULL || clientBuffer == NULL || frames == 0) { return; }

    Float32* client = (Float32*)clientBuffer;
    // Position in the ring (in frames), wrapped to the buffer length.
    SInt64 startFrame = (SInt64)sampleTime;
    UInt32 pos = (UInt32)(((startFrame % kRingBufferFrames) + kRingBufferFrames) % kRingBufferFrames);

    UInt32 firstChunk = frames;
    if (pos + firstChunk > kRingBufferFrames) { firstChunk = kRingBufferFrames - pos; }
    UInt32 secondChunk = frames - firstChunk;

    Float32* ringAt = dev->ring + (size_t)pos * kChannelsPerFrame;
    size_t firstBytes  = (size_t)firstChunk  * kChannelsPerFrame * sizeof(Float32);
    size_t secondBytes = (size_t)secondChunk * kChannelsPerFrame * sizeof(Float32);

    if (ringToClient) {
        memcpy(client, ringAt, firstBytes);
        if (secondChunk) { memcpy(client + (size_t)firstChunk * kChannelsPerFrame, dev->ring, secondBytes); }
    } else {
        memcpy(ringAt, client, firstBytes);
        if (secondChunk) { memcpy(dev->ring, client + (size_t)firstChunk * kChannelsPerFrame, secondBytes); }
    }
}

static OSStatus MuteMaster_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    DeviceState* dev = DeviceForID(inDeviceObjectID);
    if (dev == NULL || inIOCycleInfo == NULL) { return kAudioHardwareBadObjectError; }

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        // Client is writing to the device's OUTPUT stream → store into the loopback ring.
        RingCopy(dev, inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, ioMainBuffer, /*ringToClient*/false);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        // Client is reading the device's INPUT stream → deliver from the loopback ring.
        RingCopy(dev, inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, ioMainBuffer, /*ringToClient*/true);
    }
    return noErr;
}

static OSStatus MuteMaster_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}
