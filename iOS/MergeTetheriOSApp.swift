import SwiftUI
@main struct MergeTetheriOSApp: App {
    @State private var model = RemotePhoneModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RemoteBoardView(model: model)
                .onOpenURL { model.offerPairing($0.absoluteString) }
                .onChange(of: phase, initial: true) {
                    if phase == .active { model.connect() } else { model.disconnect() }
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
