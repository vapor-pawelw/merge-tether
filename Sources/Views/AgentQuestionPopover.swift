import SwiftUI

struct AgentQuestionPopover: View {
    let conversation: AgentQuestionConversation
    let submit: (String) -> Void
    let openLink: (URL) -> OpenURLAction.Result
    @State private var question = ""
    @FocusState private var inputFocused: Bool

    private var canSend: Bool {
        !conversation.isRunning && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(.AgentQuestion.agentQuestionTitle).font(.headline)
                Spacer()
                Button { conversation.clear(); inputFocused = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(Text(.AgentQuestion.agentQuestionClear))
                .accessibilityLabel(Text(.AgentQuestion.agentQuestionClear))
                .disabled(conversation.messages.isEmpty && !conversation.isRunning)
            }
            .padding(12)
            Divider()
            transcript
            Divider()
            if let failure = conversation.failure {
                Text(failure == .answer ? .AgentQuestion.agentQuestionFailed : .AgentQuestion.agentQuestionStorageFailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(width: 430, height: 450)
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
                                ExtraContextMarkdown(source: message.text)
                                    .environment(\.openURL, OpenURLAction(handler: openLink))
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
            .frame(maxWidth: 350, alignment: .leading)
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
