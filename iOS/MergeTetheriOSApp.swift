import SwiftUI
@main struct MergeTetheriOSApp: App {
    @State private var model = makeModel()
    @Environment(\.scenePhase) private var phase
    @MainActor private static func makeModel() -> RemotePhoneModel {
        #if DEBUG
        if let preview = RemoteDemo.makeModel() { return preview }
        #endif
        return RemotePhoneModel()
    }
    var body: some Scene {
        WindowGroup {
            RemoteBoardView(model: model)
                .environment(\.remoteAvatarThumbnails, model.avatarThumbnails)
                .environment(\.codingProviderGlyph, model.state.board?.codingProvider.flatMap(CodingProviderGlyph.init(rawValue:)))
                .onOpenURL { model.offerPairing($0.absoluteString) }
                .onChange(of: phase, initial: true) {
                    switch phase {
                    case .active: model.sceneChanged(.active)
                    case .background: model.sceneChanged(.background)
                    default: model.sceneChanged(.inactive)
                    }
                }
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    }
                }
        }
    }
}
