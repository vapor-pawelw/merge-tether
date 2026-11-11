import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessView: View {
    @Bindable var remote: RemoteHostController
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(.Remote.remoteMacPairPhone, systemImage: "iphone").font(.title2.bold())
            if let origin = remote.relayConfiguration.origin {
                Text(.Remote.remoteRelayConfigured).font(.headline)
                Text(verbatim: origin.absoluteString).font(.caption).textSelection(.enabled)
                Text(.Remote.remoteRelayOwnership).font(.caption).foregroundStyle(.secondary)
            }
            if remote.relayConfiguration.status != .configured {
                Text(remote.relayConfiguration.status == .missing ? .Remote.remoteRelayMissing : .Remote.remoteRelayInvalid)
                    .foregroundStyle(.secondary)
            } else if let pairing = remote.pairing {
                Text(.Remote.remoteMacHelp).font(.callout).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if pairing.peerPublicKey != nil {
                        Text(.Remote.remoteMacDevicePaired).foregroundStyle(.secondary)
                    } else if pairing.invitationIsValid(now: context.date) {
                        if let image = qr(pairing.deepLink.absoluteString) {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: .infinity).frame(height: 330).padding(10).background(.white)
                                .accessibilityLabel(Text(.Remote.remoteScan))
                        }
                        HStack { Text(.Remote.remoteMacInvitationExpires); Text(pairing.expiresAt, style: .time) }
                            .font(.caption).foregroundStyle(.secondary)
                        Button(.Remote.remoteCopyLink) {
                            guard pairing.invitationIsValid(), remote.pairing == pairing else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(pairing.deepLink.absoluteString, forType: .string)
                        }
                    } else {
                        Text(.Remote.remoteMacInvitationExpired).foregroundStyle(.secondary)
                    }
                }
                Button(.Remote.remoteNewCode) { remote.enable() }
                Button(.Remote.remoteDisable, role: .destructive) { remote.disable() }
            } else {
                if remote.relayMismatch { Text(.Remote.remoteRelayMismatch).font(.caption).foregroundStyle(.orange) }
                Text(.Remote.remoteRelayHelp).foregroundStyle(.secondary)
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
