//
//  Identifiers.swift
//  Shared constants used across the app, the helper, and the tests.
//
//  The device UIDs MUST match the strings the driver reports (see MuteMasterDriver.h:
//  kDevice_Mic_UID / kDevice_Spk_UID). That's how the routing engine finds our virtual devices.
//

import Foundation

public enum ZMIdentifiers {
    // Bundle IDs (must match each target's PRODUCT_BUNDLE_IDENTIFIER / Info.plist).
    public static let appBundleID    = "app.mutemaster"
    public static let driverBundleID = "app.mutemaster.driver"
    public static let helperBundleID = "app.mutemaster.helper"

    // launchd label / Mach service for the privileged helper (SMAppService).
    public static let helperPlistName   = "app.mutemaster.helper.plist"
    public static let helperMachService = "app.mutemaster.helper"

    // Virtual device UIDs — must equal the driver's reported UIDs.
    public static let mutableInputUID  = "MuteMasterInput"   // virtual mic apps read
    public static let mutableOutputUID = "MuteMasterOutput"  // virtual speaker apps write

    public static let mutableInputName  = "Mutable Microphone"
    public static let mutableOutputName = "Mutable Speaker"

    // The driver bundle name installed under /Library/Audio/Plug-Ins/HAL/.
    public static let driverBundleFileName = "MuteMasterDriver.driver"
    public static let halPluginDirectory   = "/Library/Audio/Plug-Ins/HAL"
}

public enum ZMDefaultsKey {
    public static let realInputDeviceUID  = "realInputDeviceUID"   // selected real mic UID
    public static let realOutputDeviceUID = "realOutputDeviceUID"  // selected real speaker UID
    public static let inputMuted          = "inputMuted"
    public static let outputMuted         = "outputMuted"
}
