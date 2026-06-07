//
//  main.swift
//  Entry point for the privileged helper daemon. Sets up an XPC listener on the Mach service named
//  in the launchd plist and vends a HelperService for each incoming connection.
//
//  Security: only our app should be allowed to drive the helper. We pin the connecting client's
//  code-signing requirement to our app's Team/bundle id (see acceptConnection). For local-dev with
//  ad-hoc signing this requirement is relaxed; tighten it for distribution (see README/M6).
//

import Foundation

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // TODO (M6 / distribution): validate newConnection.auditToken against our app's designated
        // code requirement before accepting. For local dev we accept and rely on the private Mach
        // service only being reachable by processes that know its name.
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: ZMIdentifiers.helperMachService)
listener.delegate = delegate
listener.resume()        // returns immediately
RunLoop.main.run()       // keep the daemon alive
