import SwiftUI

struct AutoHandledEventBannerView: View {
    let event: AutoHandledEventBannerCenter.Event
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(action).font(.subheadline)
                Text(verbatim: "\(event.projectPath) !\(event.target.iid ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(.TodoRouting.todoRoutingBannerDismiss))
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .task(id: event.id) {
            let remaining = max(0, event.expiresAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            dismiss()
        }
    }

    private var action: LocalizedStringResource {
        switch event.kind {
        case .review: .TodoRouting.todoRoutingBannerReview
        case .followUp: .TodoRouting.todoRoutingBannerFollowUp
        case .pipeline: .TodoRouting.todoRoutingBannerPipeline
        case .conflict: .TodoRouting.todoRoutingBannerConflict
        case .refresh: .TodoRouting.todoRoutingBannerRefresh
        case .merged: .MRLifecycleBanners.mrLifecycleBannersMerged
        case .closed: .MRLifecycleBanners.mrLifecycleBannersClosed
        case .ready: .MRLifecycleBanners.mrLifecycleBannersReady
        case .draft: .MRLifecycleBanners.mrLifecycleBannersDraft
        }
    }

    private var title: LocalizedStringResource {
        switch event.kind {
        case .merged: .MRLifecycleBanners.mrLifecycleBannersMergedTitle
        case .closed: .MRLifecycleBanners.mrLifecycleBannersClosedTitle
        case .ready: .MRLifecycleBanners.mrLifecycleBannersReadyTitle
        case .draft: .MRLifecycleBanners.mrLifecycleBannersDraftTitle
        case .review, .followUp, .pipeline, .conflict, .refresh: .TodoRouting.todoRoutingBannerAccepted
        }
    }

    private var symbol: String {
        switch event.kind {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle.fill"
        case .draft: "doc.text"
        case .ready, .review, .followUp, .pipeline, .conflict, .refresh: "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .merged: .purple
        case .closed, .draft: .secondary
        case .ready: .accentColor
        case .review, .followUp, .pipeline, .conflict, .refresh: .green
        }
    }
}
