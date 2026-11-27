import AppKit
import SwiftUI

struct AgentQuestionSheet: View {
    let conversation: AgentQuestionConversation
    let configuration: AgentQuestionCLI.Configuration
    let submit: (String) -> Void
    var canOpenLink: (URL) -> Bool = { _ in false }
    let openLink: (URL) -> OpenURLAction.Result
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @FocusState private var inputFocused: Bool

    private var canSend: Bool {
        !conversation.isRunning && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(.AgentQuestion.agentQuestionTitle).font(.headline)
                    Text(.AgentQuestion.agentQuestionModelAndEffort(configuration.modelName, String(localized: configuration.thinking.name)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { conversation.clear(); inputFocused = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(Text(.AgentQuestion.agentQuestionClear))
                .accessibilityLabel(Text(.AgentQuestion.agentQuestionClear))
                .disabled(conversation.messages.isEmpty && !conversation.isRunning)
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help(Text(.CommandCenter.commandCenterClose))
                    .accessibilityLabel(Text(.CommandCenter.commandCenterClose))
            }
            .padding(12)
            Divider()
            transcript
            Divider()
            if conversation.failure != nil || conversation.unansweredQuestion != nil {
                HStack {
                    if let failure = conversation.failure {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let text = conversation.unansweredQuestion {
                        Button { submit(text); inputFocused = true } label: { Text(.AgentQuestion.agentQuestionRetry) }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $question, prompt: Text(.AgentQuestion.agentQuestionPlaceholder)) {
                    Text(.AgentQuestion.agentQuestionPlaceholder)
                }
                .labelsHidden()
                .focused($inputFocused)
                .onSubmit(send)
                .onChange(of: question) { _, value in
                    if value.count > AgentQuestionInput.maximumLength {
                        question = String(value.prefix(AgentQuestionInput.maximumLength))
                    }
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
                .help(Text(.AgentQuestion.agentQuestionSend))
                .accessibilityLabel(Text(.AgentQuestion.agentQuestionSend))
            }
            .padding(12)
        }
        .frame(minWidth: 540, idealWidth: 690, minHeight: 460, idealHeight: 600)
        .onAppear { inputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 10) {
                    bubble(user: false) { messageText(String(localized: .AgentQuestion.agentQuestionWelcome)) }
                    ForEach(conversation.messages) { message in
                        bubble(user: message.role == .user) {
                            switch message.role {
                            case .user: messageText(message.text)
                            case .refusal: messageText(String(localized: .AgentQuestion.agentQuestionReadOnly))
                            case .agent:
                                messageText(message.text, markdown: true) { url in
                                    if let handle = message.people?[url]?.username { return handle.hasPrefix("@") ? handle : "@" + handle }
                                    if message.people?[url] != nil || message.noteLinks?.contains(url) == true || canOpenLink(url) {
                                        return url.absoluteString
                                    }
                                    return nil
                                }
                                    .environment(\.openURL, OpenURLAction { url in
                                        if message.people?[url] != nil || message.noteLinks?.contains(url) == true { return .systemAction }
                                        return openLink(url)
                                    })
                                if let notice = message.sourceNotice {
                                    Text(notice == .mainFallback ? .AgentQuestion.agentQuestionSourceMain
                                         : .AgentQuestion.agentQuestionSourceUnavailable)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if conversation.isRunning {
                        bubble(user: false) {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(Text(.AgentQuestion.agentQuestionThinking))
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onAppear { scroll.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.messages.last?.id) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
            .onChange(of: conversation.isRunning) { _, _ in scroll.scrollTo("end", anchor: .bottom) }
        }
    }

    private func messageText(_ text: String, markdown: Bool = false,
                             linkTooltip: (URL) -> String? = { _ in nil }) -> some View {
        AgentQuestionMessageText(content: AgentQuestionMessageText.render(text, markdown: markdown, linkTooltip: linkTooltip))
    }

    private func bubble<Content: View>(user: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: 525, alignment: .leading)
            .background(user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }

    private func send() {
        guard canSend else { return }
        submit(question)
        question = ""
        inputFocused = true
    }
}

private struct AgentQuestionMessageText: NSViewRepresentable {
    let content: NSAttributedString
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator { Coordinator(openURL: openURL) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isVerticallyResizable = false
        view.drawsBackground = false
        view.displaysLinkToolTips = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.openURL = openURL
        if let storage = view.textStorage, !storage.isEqual(to: content) { storage.setAttributedString(content) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = proposal.width ?? 505
        guard width.isFinite, width > 0 else { return .zero }
        container.size = .init(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return .init(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: OpenURLAction

        init(openURL: OpenURLAction) { self.openURL = openURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { openURL(url) }
            return true
        }
    }

    static func render(_ text: String, markdown: Bool, linkTooltip: (URL) -> String?) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .callout, options: [:])
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor]
        guard markdown else { return NSAttributedString(string: text, attributes: plain) }
        let content = NSMutableAttributedString()

        for block in ExtraContextMarkdownBlock.parse(text) {
            if content.length > 0 { content.append(NSAttributedString(string: "\n\n", attributes: plain)) }
            var attributes = plain
            let source: String
            switch block {
            case .paragraph(let text): source = text
            case .heading(let level, let text):
                let style: NSFont.TextStyle = level == 1 ? .title3 : level == 2 ? .headline : .subheadline
                let font = NSFont.preferredFont(forTextStyle: style, options: [:])
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                source = text
            case .item(let marker, let text, let indent):
                source = String(repeating: "    ", count: indent) + marker + " " + text
            case .quote(let text):
                let paragraph = NSMutableParagraphStyle()
                paragraph.headIndent = 10
                paragraph.firstLineHeadIndent = 10
                attributes[.paragraphStyle] = paragraph
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                source = text
            case .code(let text):
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
                content.append(NSAttributedString(string: text, attributes: attributes))
                continue
            case .rule:
                content.append(NSAttributedString(string: "────────", attributes: [.font: body, .foregroundColor: NSColor.separatorColor]))
                continue
            }
            let inline = ExtraContextMarkdownBlock.inline(source)
            for run in inline.runs {
                var style = attributes
                var font = attributes[.font] as? NSFont ?? body
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                style[.font] = font
                if let url = run.link, let tooltip = linkTooltip(url) {
                    style[.link] = url
                    style[.toolTip] = tooltip
                }
                content.append(NSAttributedString(string: String(inline[run.range].characters), attributes: style))
            }
        }
        return content
    }
}
