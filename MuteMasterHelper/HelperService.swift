//
//  HelperService.swift
//  The privileged side of the XPC contract. Runs as root (launchd daemon) and performs the two
//  operations the app can't: copying the driver into /Library/Audio/Plug-Ins/HAL and restarting
//  coreaudiod.
//

import Foundation

final class HelperService: NSObject, HelperProtocol {

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(HelperInfo.version)
    }

    func installDriver(fromBundlePath sourcePath: String, withReply reply: @escaping (Bool, String?) -> Void) {
        let fm = FileManager.default
        let halDir = ZMIdentifiers.halPluginDirectory
        let destPath = (halDir as NSString).appendingPathComponent(ZMIdentifiers.driverBundleFileName)

        // Basic validation: the source must exist and be a .driver bundle.
        guard fm.fileExists(atPath: sourcePath),
              (sourcePath as NSString).pathExtension == "driver" else {
            reply(false, "Source driver bundle not found at \(sourcePath)")
            return
        }

        do {
            if !fm.fileExists(atPath: halDir) {
                try fm.createDirectory(atPath: halDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: destPath) {
                try fm.removeItem(atPath: destPath)
            }
            try fm.copyItem(atPath: sourcePath, toPath: destPath)
            try setOwnership(rootWheel: destPath)
        } catch {
            reply(false, "Copy failed: \(error.localizedDescription)")
            return
        }

        restartCoreAudio { ok, err in
            reply(ok, ok ? nil : (err ?? "coreaudiod restart failed"))
        }
    }

    func restartCoreAudio(withReply reply: @escaping (Bool, String?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["coreaudiod"]
        do {
            try task.run()
            task.waitUntilExit()
            // killall exits non-zero if the process wasn't running; treat that as benign.
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    /// Recursively set root:wheel ownership so coreaudiod will trust and load the bundle.
    private func setOwnership(rootWheel path: String) throws {
        let attrs: [FileAttributeKey: Any] = [.ownerAccountID: 0, .groupOwnerAccountID: 0]
        let fm = FileManager.default
        try fm.setAttributes(attrs, ofItemAtPath: path)
        if let enumerator = fm.enumerator(atPath: path) {
            for case let sub as String in enumerator {
                try? fm.setAttributes(attrs, ofItemAtPath: (path as NSString).appendingPathComponent(sub))
            }
        }
    }
}
