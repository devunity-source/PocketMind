import SwiftUI
import PocketMindCore

struct RecordingDetailView: View {
    let route: RecordingRoute

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var player: AudioPlayerService
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var recorder: AudioRecorderService
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript", speakers = "Speakers" }

    @State private var recording: Recording?
    @State private var segments: [TranscriptSegment] = []
    @State private var speakers: [Speaker] = []
    @State private var summary: MeetingSummary?
    @State private var tasks: [TaskItem] = []
    @State private var templates: [SummaryTemplate] = SummaryTemplate.builtIns
    @State private var folders: [Folder] = []
    @State private var tab: Tab = .summary
    @State private var didApplyRoute = false

    @State private var editingSegment: TranscriptSegment?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var tagText = ""
    @State private var showTags = false
    @State private var pendingExport: ExportKind?
    @State private var shareItem: ShareItem?
    @State private var errorMessage: String?

    enum ExportKind: String, Identifiable {
        case text, markdown, audio
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if let recording {
                content(recording)
            } else {
                EmptyStateView(icon: "questionmark.folder", title: "Recording not found",
                               message: "It may have been deleted.")
            }
        }
        .screenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let recording { ToolbarItem(placement: .topBarTrailing) { menu(recording) } } }
        .task(id: "\(environment.revision)-\(pipeline.revision)") { await reload() }
        .onDisappear { player.pause() }
        .sheet(item: $editingSegment) { segment in
            SegmentEditor(segment: segment) { text in
                try? environment.store.updateSegmentText(id: segment.id, text: text)
                environment.touch()
            }
        }
        .sheet(item: $shareItem) { ShareSheet(url: $0.url) }
        .alert("Rename recording", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") { update { $0.title = renameText.trimmingCharacters(in: .whitespaces).isEmpty ? $0.title : renameText } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Tags", isPresented: $showTags) {
            TextField("comma, separated", text: $tagText)
            Button("Save") {
                update { $0.tags = tagText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Export leaves the encrypted vault", isPresented: Binding(
            get: { pendingExport != nil }, set: { if !$0 { pendingExport = nil } }), titleVisibility: .visible) {
            Button("Export unencrypted copy") { runExport() }
            Button("Cancel", role: .cancel) { pendingExport = nil }
        } message: {
            Text("The exported file is not encrypted. Anyone you share it with, and any app you send it to, can read it. PocketMind cannot delete copies outside the app.")
        }
    }

    // MARK: Layout

    private func content(_ recording: Recording) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    header(recording)
                    PlayerCard(recording: recording, disabled: recorder.isActive)
                    if let job = pipeline.job(for: recording.id) {
                        Card(padding: Theme.Spacing.m) { ProcessingRow(job: job) }
                    } else if recording.status == .failed {
                        failureCard(recording)
                    }
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch tab {
                    case .summary: summaryTab(recording)
                    case .transcript: transcriptTab(recording)
                    case .speakers: speakersTab(recording)
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .onChange(of: segments.count) { _, _ in applyRoute(proxy) }
            .onChange(of: player.loadedRecordingID) { _, _ in applyRoute(proxy) }
        }
    }

    private func header(_ recording: Recording) -> some View {
        VStack(spacing: 4) {
            Text(recording.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("\(Format.dateTime(recording.createdAt)) · \(Format.shortDuration(recording.duration))"
                 + (recording.language.map { " · \(SupportedLanguage.name(for: $0))" } ?? ""))
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            if !recording.tags.isEmpty {
                Text(recording.tags.map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption).foregroundStyle(Theme.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func failureCard(_ recording: Recording) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Processing failed", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.Palette.danger)
                    .font(.subheadline.weight(.semibold))
                Text(recording.errorMessage ?? "Unknown error").font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                Button("Try again") {
                    pipeline.enqueue(recordingID: recording.id, transcribe: segments.isEmpty, summarize: true)
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summaryTab(_ recording: Recording) -> some View {
        if let summary {
            if !summary.isFromLanguageModel {
                Card(padding: Theme.Spacing.m) {
                    Label("Basic summary: sentences quoted from the transcript. Install a language model in Settings → AI Models for written summaries.",
                          systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            if !summary.overview.isEmpty {
                summaryCard("Meeting Summary", icon: "doc.text") {
                    Text(summary.overview).font(.subheadline).foregroundStyle(Theme.Palette.textPrimary)
                }
            }
            bulletCard("Key Points", icon: "list.bullet", summary.keyPoints)
            bulletCard("Key Decisions", icon: "checkmark.seal", summary.decisions)
            if !tasks.isEmpty {
                summaryCard("Action Items (\(tasks.count))", icon: "checklist") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(tasks) { task in
                            TaskRow(task: task, sourceTitle: nil) { toggle(task) }
                        }
                    }
                }
            }
            bulletCard("Deadlines", icon: "calendar", summary.deadlines.map { "\($0.what) — \($0.when)" })
            bulletCard("Important Facts", icon: "lightbulb", summary.facts)
            bulletCard("Follow-up Questions", icon: "questionmark.bubble", summary.followUpQuestions)

            if summary.overview.isEmpty && summary.keyPoints.isEmpty && summary.decisions.isEmpty && tasks.isEmpty {
                EmptyStateView(icon: "text.badge.minus", title: "Nothing to summarize",
                               message: "The transcript did not contain enough to build a summary from.")
            }
            summarizeMenu(recording, title: "Regenerate summary")
        } else if segments.isEmpty {
            EmptyStateView(icon: "waveform.slash", title: "No transcript yet",
                           message: models.activeWhisperModel == nil
                               ? "Install a speech model in Settings → AI Models, then transcribe this recording."
                               : "Transcribe this recording to get a summary.")
            transcribeButton(recording)
        } else {
            EmptyStateView(icon: "sparkles", title: "No summary yet", message: "Create a summary from the transcript.")
            summarizeMenu(recording, title: "Summarize")
        }
    }

    private func summaryCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
                content()
            }
        }
    }

    @ViewBuilder
    private func bulletCard(_ title: String, icon: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            summaryCard(title, icon: icon) {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                            Text("•").foregroundStyle(Theme.Palette.accent)
                            Text(item).font(.subheadline).foregroundStyle(Theme.Palette.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private func summarizeMenu(_ recording: Recording, title: String) -> some View {
        Menu {
            ForEach(templates) { template in
                Button(template.name) {
                    pipeline.enqueue(recordingID: recording.id, transcribe: false, summarize: true, templateID: template.id)
                }
            }
        } label: {
            Label(title, systemImage: "sparkles").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(pipeline.job(for: recording.id) != nil)
    }

    private func transcribeButton(_ recording: Recording) -> some View {
        Menu {
            Button("Detect language automatically") { startTranscription(recording, language: nil) }
            ForEach(SupportedLanguage.allCases) { language in
                Button(language.name) { startTranscription(recording, language: language.rawValue) }
            }
        } label: {
            Label(segments.isEmpty ? "Transcribe" : "Transcribe again", systemImage: "waveform").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(models.activeWhisperModel == nil || pipeline.job(for: recording.id) != nil)
    }

    private func startTranscription(_ recording: Recording, language: String?) {
        pipeline.enqueue(recordingID: recording.id, transcribe: true,
                         summarize: environment.settings.autoSummarize, language: language)
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcriptTab(_ recording: Recording) -> some View {
        if segments.isEmpty {
            EmptyStateView(icon: "text.alignleft", title: "No transcript yet",
                           message: models.activeWhisperModel == nil
                               ? "Install a speech model in Settings → AI Models first."
                               : "Estimated time: \(pipeline.transcriptionEstimate(for: recording)).")
            transcribeButton(recording)
        } else {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(segments) { segment in
                    segmentRow(segment, recording: recording)
                        .id(segment.id)
                }
            }
            Text("Tap a line to play from there. Touch and hold to correct the text or set the speaker.")
                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            transcribeButton(recording)
        }
    }

    private func isCurrent(_ segment: TranscriptSegment) -> Bool {
        player.loadedRecordingID == segment.recordingID && player.isPlaying
            && player.currentTime >= segment.start && player.currentTime < segment.end
    }

    private func segmentRow(_ segment: TranscriptSegment, recording: Recording) -> some View {
        let speaker = speakers.first { $0.id == segment.speakerID }
        return Button {
            Task {
                await player.load(recording)
                player.seek(to: segment.start, autoplay: true)
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Text(Format.duration(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    if let speaker {
                        Text(speaker.displayName).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Text(segment.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    if segment.isEdited {
                        Text("Edited").font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.s)
            .background(isCurrent(segment) ? Theme.Palette.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingSegment = segment } label: { Label("Correct text", systemImage: "pencil") }
            Menu {
                ForEach(speakers) { speaker in
                    Button(speaker.displayName) { assign(speaker.id, to: segment) }
                }
                Button("New speaker") {
                    if let speaker = try? environment.store.addSpeaker(recordingID: recording.id) { assign(speaker.id, to: segment) }
                }
                if segment.speakerID != nil {
                    Button("No speaker", role: .destructive) { assign(nil, to: segment) }
                }
            } label: {
                Label("Speaker", systemImage: "person.wave.2")
            }
        }
    }

    private func assign(_ speakerID: String?, to segment: TranscriptSegment) {
        try? environment.store.assignSpeaker(speakerID, toSegment: segment.id)
        environment.touch()
    }

    // MARK: Speakers

    @ViewBuilder
    private func speakersTab(_ recording: Recording) -> some View {
        Card(padding: Theme.Spacing.m) {
            Label("PocketMind does not identify voices automatically. Add speakers here, then assign them to transcript lines by touching and holding a line.",
                  systemImage: "info.circle")
                .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
        }
        ForEach(speakers) { speaker in
            SpeakerRow(speaker: speaker, lineCount: segments.filter { $0.speakerID == speaker.id }.count)
        }
        Button {
            _ = try? environment.store.addSpeaker(recordingID: recording.id)
            environment.touch()
        } label: {
            Label("Add speaker", systemImage: "plus").frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    // MARK: Menu and actions

    private func menu(_ recording: Recording) -> some View {
        Menu {
            Button { update { $0.isFavorite.toggle() } } label: {
                Label(recording.isFavorite ? "Remove from favorites" : "Add to favorites",
                      systemImage: recording.isFavorite ? "star.slash" : "star")
            }
            Button {
                renameText = recording.title
                showRename = true
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                tagText = recording.tags.joined(separator: ", ")
                showTags = true
            } label: { Label("Edit tags", systemImage: "tag") }
            Menu {
                ForEach(RecordingKind.allCases, id: \.self) { kind in
                    Button { update { $0.kind = kind } } label: {
                        if recording.kind == kind { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                    }
                }
            } label: { Label("Category", systemImage: "square.grid.2x2") }
            Menu {
                Button { update { $0.folderID = nil } } label: {
                    if recording.folderID == nil { Label("No folder", systemImage: "checkmark") } else { Text("No folder") }
                }
                ForEach(folders) { folder in
                    Button { update { $0.folderID = folder.id } } label: {
                        if recording.folderID == folder.id { Label(folder.name, systemImage: "checkmark") } else { Text(folder.name) }
                    }
                }
            } label: { Label("Folder", systemImage: "folder") }

            Divider()
            Button { pendingExport = .text } label: { Label("Export transcript (TXT)", systemImage: "doc.plaintext") }
                .disabled(segments.isEmpty)
            Button { pendingExport = .markdown } label: { Label("Export notes (Markdown)", systemImage: "doc.richtext") }
                .disabled(segments.isEmpty)
            Button { pendingExport = .audio } label: { Label("Share audio", systemImage: "square.and.arrow.up") }

            Divider()
            Button(role: .destructive) {
                environment.moveToTrash(recording)
                dismiss()
            } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Recording actions")
    }

    private func update(_ change: (inout Recording) -> Void) {
        guard var current = recording else { return }
        change(&current)
        try? environment.store.save(current)
        environment.touch()
    }

    private func toggle(_ task: TaskItem) {
        try? environment.store.setTaskDone(!task.isDone, id: task.id)
        environment.touch()
    }

    private func runExport() {
        guard let recording, let kind = pendingExport else { return }
        pendingExport = nil
        Task {
            do {
                let url: URL
                switch kind {
                case .text: url = try environment.exportTranscript(recording, markdown: false)
                case .markdown: url = try environment.exportTranscript(recording, markdown: true)
                case .audio: url = try await environment.exportAudio(recording)
                }
                shareItem = ShareItem(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reload() async {
        let store = environment.store
        recording = try? store.recording(id: route.recordingID)
        guard let recording else { return }
        segments = (try? store.segments(recordingID: recording.id)) ?? []
        speakers = (try? store.speakers(recordingID: recording.id)) ?? []
        summary = try? store.summary(recordingID: recording.id)
        tasks = (try? store.tasks(.all, recordingID: recording.id)) ?? []
        templates = (try? store.allTemplates()) ?? SummaryTemplate.builtIns
        folders = (try? store.folders()) ?? []
        if !didApplyRoute, route.seekTo != nil {
            tab = .transcript
            await player.load(recording)
        }
    }

    /// Opened from a search result, a task or a memory citation: jump to that moment.
    private func applyRoute(_ proxy: ScrollViewProxy) {
        guard !didApplyRoute, let seekTo = route.seekTo, !segments.isEmpty,
              player.loadedRecordingID == route.recordingID else { return }
        didApplyRoute = true
        player.seek(to: seekTo)
        if let target = segments.last(where: { $0.start <= seekTo + 0.5 }) ?? segments.first {
            withAnimation { proxy.scrollTo(target.id, anchor: .center) }
        }
    }
}

struct PlayerCard: View {
    let recording: Recording
    let disabled: Bool
    @EnvironmentObject private var player: AudioPlayerService

    private var isLoaded: Bool { player.loadedRecordingID == recording.id }

    var body: some View {
        Card(padding: Theme.Spacing.m) {
            VStack(spacing: Theme.Spacing.s) {
                Slider(
                    value: Binding(get: { isLoaded ? player.currentTime : 0 }, set: { player.seek(to: $0) }),
                    in: 0...max(1, isLoaded ? player.duration : recording.duration))
                    .disabled(!isLoaded)
                    .accessibilityLabel("Playback position")
                HStack {
                    Text(Format.duration(isLoaded ? player.currentTime : 0))
                    Spacer()
                    Text(Format.duration(recording.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)

                HStack(spacing: Theme.Spacing.xl) {
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button(String(format: "%.2g×", value)) { player.rate = Float(value) }
                        }
                    } label: {
                        Text(String(format: "%.2g×", player.rate)).font(.subheadline.weight(.semibold)).frame(width: 48)
                    }
                    .accessibilityLabel("Playback speed")

                    Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                        .disabled(!isLoaded)
                        .accessibilityLabel("Back 15 seconds")

                    Button {
                        Task {
                            if !isLoaded { await player.load(recording) }
                            player.togglePlayback()
                        }
                    } label: {
                        Group {
                            if player.isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: isLoaded && player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Theme.Palette.accent, in: Circle())
                    }
                    .disabled(disabled || player.isLoading)
                    .accessibilityLabel(isLoaded && player.isPlaying ? "Pause" : "Play")

                    Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.title3) }
                        .disabled(!isLoaded)
                        .accessibilityLabel("Forward 15 seconds")

                    Color.clear.frame(width: 48, height: 1)
                }
                .foregroundStyle(Theme.Palette.textPrimary)

                if disabled {
                    Text("Playback is unavailable while recording.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                if let error = player.errorMessage, isLoaded || !player.isLoading {
                    Text(error).font(.caption).foregroundStyle(Theme.Palette.danger)
                }
            }
        }
    }
}

struct SpeakerRow: View {
    let speaker: Speaker
    let lineCount: Int
    @EnvironmentObject private var environment: AppEnvironment
    @State private var name = ""
    @State private var showRename = false

    var body: some View {
        Card(padding: Theme.Spacing.m) {
            HStack {
                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.displayName).font(.subheadline.weight(.medium))
                    Text("\(speaker.label) · \(lineCount) line\(lineCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Button("Rename") {
                    name = speaker.name ?? ""
                    showRename = true
                }
                .font(.footnote.weight(.semibold))
                Button(role: .destructive) {
                    try? environment.store.deleteSpeaker(id: speaker.id)
                    environment.touch()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove speaker")
            }
        }
        .alert("Speaker name", isPresented: $showRename) {
            TextField(speaker.label, text: $name)
            Button("Save") {
                var updated = speaker
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                updated.name = trimmed.isEmpty ? nil : trimmed
                try? environment.store.save(updated)
                environment.touch()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct SegmentEditor: View {
    let segment: TranscriptSegment
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(Theme.Spacing.m)
                .scrollContentBackground(.hidden)
                .background(Theme.Palette.background)
                .navigationTitle("Correct at \(Format.duration(segment.start))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty, trimmed != segment.text { save(trimmed) }
                            dismiss()
                        }
                    }
                }
                .onAppear { text = segment.text }
        }
        .presentationDetents([.medium, .large])
    }
}
