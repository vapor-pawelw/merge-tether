import SwiftUI
import VisionKit

struct RemotePairingView: View {
    @Bindable var model: RemotePhoneModel
    @State private var link = ""
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 60)).foregroundStyle(.tint)
            Text(.Remote.remotePair).font(.title2.bold())
            Text(.Remote.remotePairHelp).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if DataScannerViewController.isSupported {
                Button(.Remote.remoteScan) { scanning = true }.buttonStyle(.borderedProminent)
            }
            SecureField(.Remote.remotePaste, text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
            Button(.Remote.remoteConnect) { model.offerPairing(link) }.buttonStyle(.bordered).disabled(link.isEmpty)
            if model.error { Text(.Remote.remoteInvalidPairing).font(.caption).foregroundStyle(.red) }
        }.padding(28)
            .alert(Text(.Remote.remotePair), isPresented: Binding(
                get: { model.pairingCandidate != nil }, set: { if !$0 { model.pairingCandidate = nil } }
            )) {
                Button(.Remote.remoteConnect) { if model.acceptPairing() { dismiss() } }
                Button(.Remote.remoteCancel, role: .cancel) { model.pairingCandidate = nil }
            } message: {
                Text(.Remote.remotePairingTrust) + Text(verbatim: "\n" + (model.pairingCandidate?.origin.absoluteString ?? ""))
            }
            .sheet(isPresented: $scanning) {
                RemoteQRScanner { value in scanning = false; model.offerPairing(value) }.ignoresSafeArea()
            }
    }
}

private struct RemoteQRScanner: UIViewControllerRepresentable {
    var scanned: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator; try? scanner.startScanning(); return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        private var delivered = false
        init(scanned: @escaping (String) -> Void) { self.scanned = scanned }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                guard !delivered, let value = barcode.payloadStringValue else { continue }
                delivered = true; dataScanner.stopScanning(); scanned(value)
            }
        }
    }
}
