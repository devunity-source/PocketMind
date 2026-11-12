import SwiftUI
import LlamaBridge
import PocketMindCore

/// Conversational search over the user's recordings. The conversation is kept in memory
/// only and disappears when the app is closed.
struct MemoryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var models: ModelManager

    struct Message: Identifiable {
        let id = UUID()
        var isUser: Bool
        var text: String
        var sources: [SourceReference] = []
        var engine: String = ""
        var isPending = false
    }

    /// Collects streamed tokens from the inference queue.
    private final class StreamBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func append(_ piece: String) { lock.lock(); text += piece; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return text }
    }

    @State private var messages: [Message] = []
    @State private var question = ""
    @State private var isAnswering = false
    @State private var flag: CancellationFlag?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Theme.Spacing.l) {
                            if messages.isEmpty { intro }
                            ForEach(messages) { message in
                                bubble(message).id(message.id)
                            }
                        }
                        .padding(Theme.Spacing.l)
                    }
                    .onChange(of: messages.last?.text) { _, _ in
                        if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                inputBar
            }
            .screenBackground()
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { messages = [] }.disabled(isAnswering)
                    }
                }
            }
            .navigationDestination(for: RecordingRoute.self) { RecordingDetailView(route: $0) }
        }
    }

    private var intro: some View {
        VStack(spacing: Theme.Spacing.l) {
            EmptyStateView(icon: "bubble.left.and.text.bubble.right", title: "Ask about your recordings",
                           message: "Answers come only from your own transcripts and always link back to the recording and moment they are based on.")
            if models.activeLanguageModel == nil {
                Card(padding: Theme.Spacing.m) {
                    Label("No language model is installed, so answers are a list of matching passages. Install one in Settings → AI Models for written answers.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            VStack(spacing: Theme.Spacing.s) {
                ForEach(MemoryService.suggestedQuestions, id: \.self) { suggestion in
                    Button { ask(suggestion) } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.m)
                            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: Message) -> some View {
        if message.isUser {
            Text(message.text)
                .font(.subheadline)
                .padding(Theme.Spacing.m)
                .foregroundStyle(.white)
                .background(Theme.Palette.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if message.isPending && message.text.isEmpty {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView()
                        Text("Searching your recordings…").font(.subheadline).foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                }
                if !message.sources.isEmpty {
                    Text("Sources (\(message.sources.count))").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    ForEach(message.sources) { source in
                        NavigationLink(value: RecordingRoute(recordingID: source.recordingID, seekTo: source.start)) {
                            HStack(spacing: Theme.Spacing.m) {
                                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(Theme.Palette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("[\(source.label)] \(source.recordingTitle)").font(.footnote.weight(.medium))
                                        .foregroundStyle(Theme.Palette.textPrimary).lineLimit(1)
                                    Text(Format.dateTime(source.recordingDate)).font(.caption2)
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                }
                                Spacer()
                                Text(Format.duration(source.start)).font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .padding(Theme.Spacing.s)
                            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                            .opacity(source.isCited || !message.engine.hasPrefix("llm:") ? 1 : 0.6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(source.recordingTitle) at \(Format.duration(source.start))")
                    }
                }
                if message.engine.hasPrefix("llm:"), !message.isPending {
                    Text("Written on this iPhone by a small language model. Check the sources before relying on it.")
                        .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.trailing, 24)
        }
    }

    private var inputBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            TextField("Ask anything…", text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused($inputFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
                .submitLabel(.send)
                .onSubmit { ask(question) }
            Button {
                if isAnswering { flag?.cancel() } else { ask(question) }
            } label: {
                Image(systemName: isAnswering ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.Palette.accent, in: Circle())
            }
            .disabled(!isAnswering && question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(isAnswering ? "Stop" : "Send")
        }
        .padding(Theme.Spacing.m)
        .background(Theme.Palette.background)
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        question = ""
        inputFocused = false
        isAnswering = true
        messages.append(Message(isUser: true, text: trimmed))
        messages.append(Message(isUser: false, text: "", isPending: true))
        let index = messages.count - 1
        let flag = CancellationFlag()
        self.flag = flag
        let buffer = StreamBuffer()

        Task {
            // Show streamed text a few times per second while the model writes.
            let refresher = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    if index < messages.count, messages[index].isPending { messages[index].text = buffer.value }
                }
            }
            defer {
                refresher.cancel()
                isAnswering = false
                self.flag = nil
            }
            do {
                var engine: (any LanguageModelEngine)?
                // The language model is only used when no transcription is running, so the
                // two models are never in memory together.
                if let model = models.activeLanguageModel, !pipeline.isBusy {
                    engine = try await pipeline.engines.languageEngine(
                        model: model, path: models.fileURL(for: model).path, useGPU: true)
                }
                let service = MemoryService(store: environment.store, llm: engine)
                let answer = try await service.answer(
                    question: trimmed, onToken: { buffer.append($0) }, isCancelled: { flag.isCancelled })
                refresher.cancel()
                guard index < messages.count else { return }
                messages[index] = Message(isUser: false, text: answer.text, sources: answer.sources, engine: answer.engine)
            } catch {
                refresher.cancel()
                guard index < messages.count else { return }
                let partial = buffer.value
                let text: String
                if case EngineError.cancelled = error {
                    text = partial.isEmpty ? "Stopped." : partial + "\n\n(Stopped.)"
                } else {
                    text = "I couldn't answer that: \(error.localizedDescription)"
                }
                messages[index] = Message(isUser: false, text: text)
            }
        }
    }
}
