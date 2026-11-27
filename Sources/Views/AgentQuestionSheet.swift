import SwiftUI

struct AgentQuestionSheet: View {
    let conversation: AgentQuestionConversation
    let configuration: AgentQuestionCLI.Configuration
    let submit: (String) -> Void
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
                    bubble(user: false) { Text(.AgentQuestion.agentQuestionWelcome) }
                    ForEach(conversation.messages) { message in
                        bubble(user: message.role == .user) {
                            switch message.role {
                            case .user: Text(verbatim: message.text).textSelection(.enabled)
                            case .refusal: Text(.AgentQuestion.agentQuestionReadOnly)
                            case .agent:
                                ExtraContextMarkdown(source: message.text, people: message.people ?? [:])
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
