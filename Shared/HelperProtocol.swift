//
//  HelperProtocol.swift
//  The XPC contract between the app (unprivileged) and the privileged helper (root). This file is
//  compiled into BOTH the app target and the helper target so both sides agree on the interface.
//
//  Installing into /Library/Audio/Plug-Ins/HAL requires root, which the sandboxed/unprivileged app
//  doesn't have — so it asks the helper (registered via SMAppService) to do the privileged copy and
//  restart coreaudiod.
//

import Foundation

@objc public protocol HelperProtocol {
    /// Copy the driver bundle at `sourcePath` into /Library/Audio/Plug-Ins/HAL (root:wheel),
    /// then restart coreaudiod so the new devices appear. Replies (success, errorMessage?).
    func installDriver(fromBundlePath sourcePath: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Restart coreaudiod (useful after a manual driver update). Replies (success, errorMessage?).
    func restartCoreAudio(withReply reply: @escaping (Bool, String?) -> Void)

    /// Returns the helper's version string so the app can detect a stale helper.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}

/// Bumped whenever the helper's behavior changes; app compares to decide whether to re-register.
public enum HelperInfo {
    public static let version = "1"
}
