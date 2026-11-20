import SwiftUI
import VisionKit

struct RemotePairingView: View {
    @Bindable var model: RemotePhoneModel
    @State private var link = ""
    @State private var scanning = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let origin = model.relayConfiguration.origin
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(.Remote.remotePair).accessibilityAddTraits(.isHeader)
                    } icon: {
                        Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(.tint)
                    }
                    .font(.title2.bold())

                    if origin != nil {
                        Text(.Remote.remotePairHelp).foregroundStyle(.secondary)
                    }
                }

                if origin != nil {
                    pairingControls
                } else {
                    Text(model.relayConfiguration.status == .missing ? .Remote.remoteRelayMissing : .Remote.remoteRelayInvalid)
                        .foregroundStyle(.secondary)
                }

                if model.relayMismatch {
                    Text(.Remote.remoteRelayMismatch).font(.footnote).foregroundStyle(.orange)
                } else if model.error {
                    Text(.Remote.remoteInvalidPairing).font(.footnote).foregroundStyle(.red)
                }

                if let origin {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(.Remote.remoteRelayAddress).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(verbatim: origin.absoluteString)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
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

    private var pairingControls: some View {
        let manualLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 12) {
            if DataScannerViewController.isSupported {
                Button { scanning = true } label: {
                    Label(.Remote.remoteScan, systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            manualLayout {
                SecureField(.Remote.remotePaste, text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                Button { model.offerPairing(link) } label: {
                    Text(.Remote.remoteConnect)
                        .fontWeight(.semibold)
                        .foregroundStyle(link.isEmpty ? Color.secondary : Color.accentColor)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(link.isEmpty)
            }
        }
        .controlSize(.large)
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
