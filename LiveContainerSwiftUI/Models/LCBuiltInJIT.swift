import Foundation
import Combine
import CryptoKit

/// Validates the remote-pairing format consumed by the bundled idevice engine.
enum LCPairingRecord {
    static func validate(_ data: Data) throws {
        guard data.count < 2_000_000,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data, publicKey.count == 32,
              let privateKey = plist["private_key"] as? Data, privateKey.count == 32,
              let identifier = plist["identifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey),
              key.publicKey.rawRepresentation == publicKey else {
            throw NSError(domain: "LCBuiltInJIT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "lc.jit.error.pairing".loc])
        }
    }
}

/// Enables JIT through the bundled helper extension (`JITHelper.appex`).
///
/// The helper is a second process because a process cannot attach a debugger to
/// itself. The host only prepares the request and follows the helper's status
/// file; the guest process itself waits for `CS_DEBUGGED` before it starts.
@MainActor
enum LCBuiltInJIT {
    private static var busy = false

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT")
    }

    static var pairingURL: URL { directory.appendingPathComponent("pairingFile.plist") }

    private static var statusURL: URL { directory.appendingPathComponent("last-status.json") }

    static var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    static func importPairing(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        try LCPairingRecord.validate(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtection])
    }

    static func removePairing() throws {
        try? FileManager.default.removeItem(at: pairingURL)
    }

    /// `pid` must belong to a separate guest process; `prepare` and `reset` ignore it.
    static func enable(pid: Int32 = getpid(), script: String?, operation: String = "enable",
                       progress: @escaping (String) -> Void) async -> Bool {
        func report(_ message: String, done: Bool = false, success: Bool = false) {
            progress(message)
            let status: [String: Any] = ["message": message, "done": done, "success": success,
                                         "operation": operation, "targetPID": pid,
                                         "timestamp": Date().timeIntervalSince1970]
            if let data = try? JSONSerialization.data(withJSONObject: status) {
                try? data.write(to: statusURL, options: .atomic)
            }
        }

        guard !busy else { report("lc.jit.error.busy".loc); return false }
        guard ["enable", "prepare", "reset"].contains(operation),
              operation != "enable" || (pid > 0 && pid != getpid()) else {
            report("lc.jit.error.guestProcess".loc); return false
        }
        busy = true
        defer { busy = false }

        guard #available(iOS 17.4, *) else { report("lc.jit.error.ios".loc); return false }
        guard LCUtils.strataCanDebug() else { report("lc.jit.error.debug".loc); return false }
        guard let data = try? Data(contentsOf: pairingURL) else {
            report("lc.jit.error.noPairing".loc); return false
        }
        do { try LCPairingRecord.validate(data) } catch { report(error.localizedDescription); return false }
        guard let group = LCSharedUtils.appGroupID(),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            report("lc.jit.error.appGroup".loc); return false
        }

        let preferences = LCUtils.appGroupUserDefault
        let rawAddress = preferences.string(forKey: "LCBuiltInJITDeviceAddress") ?? "10.7.0.1"
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/")[0]
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        let portText = preferences.string(forKey: "LCBuiltInJITRemotePairPort") ?? "49152"
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }),
              let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            report("lc.jit.error.endpoint".loc); return false
        }

        let token = UUID().uuidString
        let status = root.appendingPathComponent("Library/StrataJIT/\(token).json")
        var helper: NSObject?
        defer {
            if let helper { LCUtils.strataStopJITHelper(helper) }
            try? FileManager.default.removeItem(at: status)
            if operation == "enable" {
                LCUtils.appGroupUserDefault.removeObject(forKey: "LCBuiltInJITWait")
            }
        }

        do {
            if operation == "enable" {
                report(String(format: "lc.jit.status.guestAck".loc, pid))
            }
            helper = try LCUtils.strataStartJITHelper([
                "strataJIT": true,
                "group": group,
                "operation": operation,
                "token": token,
                "pid": pid,
                "pairing": data,
                "script": script ?? "",
                "deviceAddress": address,
                "remotePairPort": Int(port),
            ])
            guard helper != nil else { report("lc.jit.error.helperMissing".loc); return false }
            report("lc.jit.status.preparing".loc)

            let started = Date()
            let deadline = started.addingTimeInterval(300)
            var receivedStatus = false
            var lastMessage = ""
            while Date() < deadline {
                try Task.checkCancellation()
                if let bytes = try? Data(contentsOf: status),
                   let result = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    receivedStatus = true
                    let message = result["message"] as? String ?? ""
                    if message != lastMessage { report(message); lastMessage = message }
                    if result["done"] as? Bool == true {
                        return result["success"] as? Bool == true
                    }
                }
                if !receivedStatus && Date().timeIntervalSince(started) > 12 {
                    report("lc.jit.error.notStarted".loc)
                    return false
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            report("lc.jit.error.timeout".loc)
        } catch is CancellationError {
            report("lc.jit.status.cancelled".loc)
        } catch {
            report(error.localizedDescription)
        }
        return false
    }
}

/// Owns a running JIT operation independently of any view's lifetime.
@MainActor
final class LCBuiltInJITSession: ObservableObject {
    static let shared = LCBuiltInJITSession()
    @Published var message = ""
    @Published private(set) var busy = false
    @Published private(set) var success: Bool?
    private var task: Task<Void, Never>?

    func start(_ operation: String) {
        guard !busy else { return }
        busy = true
        success = nil
        message = "lc.jit.status.starting".loc
        task = Task {
            success = await LCBuiltInJIT.enable(script: nil, operation: operation) { [weak self] line in
                self?.message = line
            }
            busy = false
            task = nil
        }
    }

    func cancel() { task?.cancel() }
}
