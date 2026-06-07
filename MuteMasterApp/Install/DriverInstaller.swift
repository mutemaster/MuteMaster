//
//  DriverInstaller.swift
//  App-side driver installation: registers the privileged helper via SMAppService, then asks it
//  (over XPC) to copy the bundled driver into /Library/Audio/Plug-Ins/HAL and restart coreaudiod.
//
//  The driver bundle ships inside the app at Contents/Resources/MuteMasterDriver.driver (a Copy Files
//  build phase puts it there). The helper copies it out to the system HAL directory.
//

import Foundation
import ServiceManagement
import os

@MainActor
final class DriverInstaller: ObservableObject {
    @Published var isWorking = false
    @Published var statusMessage: String?

    private let log = Logger(subsystem: ZMIdentifiers.appBundleID, category: "installer")

    /// Full install flow: register helper (prompting Login Items approval if needed) → XPC install.
    func installDriver(completion: @escaping (Bool) -> Void) {
        isWorking = true
        statusMessage = "Registering helper…"

        guard registerHelperIfNeeded() else {
            statusMessage = "Approve “MuteMaster” in System Settings ▸ General ▸ Login Items, then try again."
            SMAppService.openSystemSettingsLoginItems()
            isWorking = false
            completion(false)
            return
        }

        guard let driverPath = bundledDriverPath() else {
            statusMessage = "Bundled driver not found."
            isWorking = false
            completion(false)
            return
        }

        statusMessage = "Installing driver…"
        callHelper { proxy, finish in
            proxy.installDriver(fromBundlePath: driverPath) { ok, err in
                Task { @MainActor in
                    self.isWorking = false
                    self.statusMessage = ok ? "Driver installed." : "Install failed: \(err ?? "unknown error")"
                    finish()
                    completion(ok)
                }
            }
        }
    }

    // MARK: - SMAppService

    private var helperService: SMAppService {
        SMAppService.daemon(plistName: ZMIdentifiers.helperPlistName)
    }

    /// Returns true if the helper is registered and enabled. Registers it if needed.
    private func registerHelperIfNeeded() -> Bool {
        let service = helperService
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            return false
        case .notRegistered, .notFound:
            do {
                try service.register()
                return service.status == .enabled
            } catch {
                log.error("Helper register failed: \(String(describing: error), privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - XPC

    private func callHelper(_ body: @escaping (HelperProtocol, @escaping () -> Void) -> Void) {
        let connection = NSXPCConnection(machServiceName: ZMIdentifiers.helperMachService, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.resume()

        let cleanup = { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in
                self.isWorking = false
                self.statusMessage = "Helper connection failed: \(error.localizedDescription)"
            }
            cleanup()
        }) as? HelperProtocol else {
            statusMessage = "Could not reach helper."
            isWorking = false
            cleanup()
            return
        }
        body(proxy, cleanup)
    }

    // MARK: - Bundled driver location

    private func bundledDriverPath() -> String? {
        Bundle.main.url(forResource: "MuteMasterDriver", withExtension: "driver")?.path
            ?? Bundle.main.resourceURL?.appendingPathComponent(ZMIdentifiers.driverBundleFileName).path
    }
}
