import SwiftUI
import UniformTypeIdentifiers

/// Pairing import, device endpoint and developer disk image maintenance for the
/// bundled helper extension.
struct LCBuiltInJITSetupView: View {
    @AppStorage("LCBuiltInJITDeviceAddress", store: LCUtils.appGroupUserDefault) private var deviceAddress = "10.7.0.1"
    @AppStorage("LCBuiltInJITRemotePairPort", store: LCUtils.appGroupUserDefault) private var remotePairPort = "49152"
    @ObservedObject private var session = LCBuiltInJITSession.shared
    @State private var importing = false
    @State private var hasPairing = LCBuiltInJIT.hasPairing

    var body: some View {
        Form {
            Section {
                Label(hasPairing ? "lc.jit.setup.pairingImported".loc : "lc.jit.setup.pairingNeeded".loc,
                      systemImage: hasPairing ? "checkmark.circle" : "doc.badge.plus")
                Button(hasPairing ? "lc.jit.setup.replacePairing".loc : "lc.jit.setup.importPairing".loc) {
                    importing = true
                }
                if hasPairing {
                    Button("lc.jit.setup.removePairing".loc, role: .destructive) {
                        do {
                            try LCBuiltInJIT.removePairing()
                            hasPairing = false
                            session.message = "lc.jit.setup.pairingRemoved".loc
                        } catch {
                            session.message = error.localizedDescription
                        }
                    }
                }
                Label(LCUtils.strataCanDebug() ? "lc.jit.setup.debugAvailable".loc : "lc.jit.setup.debugMissing".loc,
                      systemImage: LCUtils.strataCanDebug() ? "checkmark.shield" : "exclamationmark.shield")
            } header: {
                Text("lc.jit.setup.pairing".loc)
            } footer: {
                Text("lc.jit.setup.instructions".loc)
            }

            Section {
                HStack {
                    Text("lc.jit.setup.deviceIP".loc)
                    Spacer()
                    TextField("10.7.0.1", text: $deviceAddress)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .autocorrectionDisabled()
                }
                HStack {
                    Text("lc.jit.setup.port".loc)
                    Spacer()
                    TextField("49152", text: $remotePairPort)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
            } header: {
                Text("lc.jit.setup.device".loc)
            } footer: {
                Text("lc.jit.setup.deviceHint".loc)
            }
            .disabled(session.busy)

            Section {
                Button("lc.jit.setup.prepareDevice".loc) { session.start("prepare") }
                    .disabled(session.busy || !hasPairing)
                Button("lc.jit.setup.resetDDI".loc) { session.start("reset") }
                    .disabled(session.busy || !hasPairing)
                if session.busy {
                    ProgressView("lc.jit.setup.working".loc)
                    Button("lc.jit.setup.cancel".loc, role: .cancel) { session.cancel() }
                }
                if let operationSucceeded = session.success {
                    Label(operationSucceeded ? "lc.jit.setup.completed".loc : "lc.jit.setup.failed".loc,
                          systemImage: operationSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(operationSucceeded ? Color.green : Color.orange)
                }
                if !session.message.isEmpty {
                    Text(session.message)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            } header: {
                Text("lc.jit.setup.check".loc)
            } footer: {
                Text("lc.jit.setup.launchHint".loc)
            }
        }
        .navigationTitle("lc.jit.setup.title".loc)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                try LCBuiltInJIT.importPairing(try result.get())
                hasPairing = true
                session.message = "lc.jit.setup.pairingImportedHint".loc
            } catch {
                session.message = error.localizedDescription
            }
        }
    }
}
