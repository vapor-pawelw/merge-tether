import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessView: View {
    @Bindable var remote: RemoteHostController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(.Remote.remotePair, systemImage: "iphone").font(.title2.bold())
            if let pairing = remote.pairing {
                Text(.Remote.remoteMacHelp).font(.callout).foregroundStyle(.secondary)
                if let image = qr(pairing.deepLink.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: .infinity).frame(height: 330).padding(10).background(.white)
                        .accessibilityLabel(Text(.Remote.remoteScan))
                }
                Text(verbatim: pairing.origin.absoluteString).font(.caption).foregroundStyle(.secondary)
                Button(.Remote.remoteCopyLink) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairing.deepLink.absoluteString, forType: .string)
                }
                Button(.Remote.remoteNewCode) { remote.enable() }
                Button(.Remote.remoteDisable, role: .destructive) { remote.disable() }
            } else {
                Text(.Remote.remoteRelayHelp).foregroundStyle(.secondary)
                TextField(text: $remote.origin) { Text(.Remote.remoteRelay) }.textFieldStyle(.roundedBorder)
                SecureField(text: $remote.invitation) { Text(.Remote.remoteInvitation) }.textFieldStyle(.roundedBorder)
                Button(.Remote.remoteEnable) { remote.enable() }.buttonStyle(.borderedProminent)
                    .disabled(remote.origin.isEmpty || remote.invitation.isEmpty)
            }
            if remote.failed { Text(.Remote.remoteError).foregroundStyle(.red).font(.caption) }
        }.padding(24).frame(width: 440)
    }
    private func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8)
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
