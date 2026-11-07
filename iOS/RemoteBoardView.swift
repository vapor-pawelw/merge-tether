import SwiftUI
import MergeTetherRemote

struct RemoteBoardView: View {
    @Bindable var model: RemotePhoneModel
    @State private var pairingSheet = false
    @State private var selected: RemoteCard?
    var body: some View {
        NavigationStack {
            Group {
                if !model.paired { RemotePairingView(model: model) }
                else if let board = model.state.board {
                    VStack(alignment: .leading, spacing: 12) {
                        connectionStatus
                        if board.partial { Text(.Remote.remotePartial).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 14) {
                                ForEach(board.lanes) { lane in
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack { Text(lane.id.title).font(.headline); Spacer(); Text(lane.cards.count, format: .number).foregroundStyle(.secondary) }
                                        ScrollView {
                                            LazyVStack(spacing: 10) {
                                                if lane.cards.isEmpty { Text(.Remote.remoteEmpty).foregroundStyle(.secondary).padding(.top, 30) }
                                                ForEach(lane.cards) { card in
                                                    Button { selected = card } label: { RemoteCardView(card: card) }.buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                    .padding(14).frame(width: 320)
                                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
                                }
                            }.padding(.horizontal).padding(.bottom)
                        }
                        if let updated = board.updatedAt {
                            HStack { Text(.Remote.remoteUpdated); Text(updated, style: .relative) }
                                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 4)
                        }
                    }
                } else {
                    ContentUnavailableView { Label(.Remote.remoteOffline, systemImage: "laptopcomputer") }
                        description: { Text(.Remote.remotePairHelp) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.error { Text(.Remote.remoteError).font(.caption).foregroundStyle(.red).padding() }
            }
            .navigationTitle(Text(.Remote.remoteTitle)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.paired {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(Text(.Remote.remoteRefresh))
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { pairingSheet = true } label: { Image(systemName: "qrcode.viewfinder") }.accessibilityLabel(Text(.Remote.remoteReplace))
                    }
                }
            }
            .alert(Text(.Remote.remotePair), isPresented: Binding(
                get: { model.paired && !pairingSheet && model.pairingCandidate != nil },
                set: { if !$0 { model.pairingCandidate = nil } }
            )) {
                Button(.Remote.remoteConnect) { model.acceptPairing() }
                Button(.Remote.remoteCancel, role: .cancel) { model.pairingCandidate = nil }
            } message: {
                Text(.Remote.remotePairingTrust) + Text(verbatim: "\n" + (model.pairingCandidate?.origin.absoluteString ?? ""))
            }
            .sheet(isPresented: $pairingSheet) { NavigationStack { RemotePairingView(model: model) }.presentationDetents([.medium, .large]) }
            .onChange(of: model.state.board?.hostSession) { pairingSheet = false }
            .sheet(item: $selected) { card in RemoteCardDetail(model: model, original: card) }
            .alert(Text(model.state.result?.status.title ?? .Remote.remoteCompleted), isPresented: Binding(
                get: { model.state.result != nil }, set: { if !$0 { model.state.acknowledgeResult() } }
            )) { Button(.Remote.remoteClose) { model.state.acknowledgeResult() } }
        }
    }
    private var connectionStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Label(model.state.canAct(now: context.date) ? .Remote.remoteConnected : .Remote.remoteOffline,
                  systemImage: model.state.canAct(now: context.date) ? "checkmark.circle.fill" : "wifi.slash")
                .font(.caption).foregroundStyle(model.state.canAct(now: context.date) ? .green : .secondary)
                .padding(.horizontal).padding(.top, 8)
        }
    }
}

struct RemoteCardView: View {
    let card: RemoteCard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: card.project).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: card.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            if !card.detail.isEmpty { Text(verbatim: card.detail).font(.caption).foregroundStyle(.secondary) }
            if !card.drafts.isEmpty { Label(.Remote.remoteComments, systemImage: "text.bubble").font(.caption).foregroundStyle(.tint) }
            if let head = card.head { Text(verbatim: String(head.prefix(8))).font(.caption2.monospaced()).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RemoteCardDetail: View {
    @Bindable var model: RemotePhoneModel
    let original: RemoteCard
    @State private var confirmation: RemoteAction?
    @Environment(\.dismiss) private var dismiss
    private var current: RemoteCard { model.state.board?.cards.first { $0.id == original.id } ?? original }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RemoteCardView(card: current)
                    if let url = current.url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link(destination: url) { Label(.Remote.remoteOpen, systemImage: "arrow.up.right.square") }
                    }
                    ForEach(current.drafts) { draft in
                        VStack(alignment: .leading, spacing: 8) {
                            if let context = draft.context { Text(verbatim: context).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Text(verbatim: draft.body).textSelection(.enabled)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let result = model.state.result {
                        Text(result.status.title).font(.callout).foregroundStyle(.secondary)
                        Button(.Remote.remoteClose) { model.state.acknowledgeResult() }
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 12) {
                            ForEach(current.actions) { action in
                                Button(action.kind.title) { confirmation = action }.buttonStyle(.borderedProminent)
                                    .disabled(!model.state.canAct(now: context.date))
                            }
                            if model.state.pending != nil { ProgressView(.Remote.remoteRunning) }
                        }
                    }
                }.padding()
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(.Remote.remoteClose) { dismiss() } } }
            .alert(Text(confirmation?.kind.title ?? .Remote.remoteConfirm), isPresented: Binding(
                get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
            )) {
                Button(.Remote.remoteConfirm) {
                    guard let action = confirmation else { return }; confirmation = nil
                    let card = current
                    Task { await model.perform(card: card, action: action) }
                }
                Button(.Remote.remoteCancel, role: .cancel) { confirmation = nil }
            } message: { Text(.Remote.remoteConfirmHelp) }
        }
    }
}
