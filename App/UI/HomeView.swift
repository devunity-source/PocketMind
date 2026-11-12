import SwiftUI
import PocketMindCore

struct HomeView: View {
    let startRecording: () -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @EnvironmentObject private var recorder: AudioRecorderService
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var router: AppRouter

    @State private var today: [Recording] = []
    @State private var recent: [Recording] = []
    @State private var highlights: [Highlight] = []

    struct Highlight: Identifiable {
        let id = UUID()
        let text: String
        let recording: Recording
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    header
                    quickActions
                    if models.activeWhisperModel == nil { setupCard }
                    if !pipeline.jobs.isEmpty { processingSection }
                    if !highlights.isEmpty { highlightsSection }
                    recordingsSection("Today", today)
                    recordingsSection("Recent", recent)
                    if today.isEmpty && recent.isEmpty {
                        EmptyStateView(icon: "mic.circle", title: "No recordings yet",
                                       message: "Tap Record to capture a meeting, a call on speaker, or a quick voice note. Everything stays on this iPhone.")
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: RecordingRoute.self) { RecordingDetailView(route: $0) }
            .navigationDestination(for: SettingsRoute.self) { _ in SettingsView() }
            .task(id: "\(environment.revision)-\(pipeline.revision)") { reload() }
        }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityHidden(true)
                Text("PocketMind").font(.title3.weight(.semibold))
            }
            HStack {
                Spacer()
                NavigationLink(value: SettingsRoute()) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: startRecording) {
                actionTile(icon: recorder.isActive ? "record.circle.fill" : "mic.fill",
                           title: recorder.isActive ? "Recording…" : "Record", tint: Theme.Palette.danger, emphasised: true)
            }
            .accessibilityHint("Starts a new recording")
            Button { router.selectedTab = .memory } label: {
                actionTile(icon: "bubble.left.and.text.bubble.right", title: "Ask Memory", tint: Theme.Palette.textPrimary)
            }
            Button { router.selectedTab = .tasks } label: {
                actionTile(icon: "checklist", title: "Tasks", tint: Theme.Palette.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private func actionTile(icon: String, title: String, tint: Color, emphasised: Bool = false) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: icon).font(.system(size: 24, weight: .medium)).foregroundStyle(tint)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(emphasised ? Theme.Palette.danger.opacity(0.14) : Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .stroke(emphasised ? Theme.Palette.danger.opacity(0.7) : Theme.Palette.stroke, lineWidth: emphasised ? 1.5 : 1))
    }

    private var setupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Label("Set up offline transcription", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
                Text("Recording works right away. To turn recordings into text, install a speech model once. After that, everything runs on this iPhone with no connection.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.textSecondary)
                NavigationLink(value: SettingsRoute()) {
                    Text("Open Settings → AI Models").font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private var processingSection: some View {
        VStack(spacing: Theme.Spacing.m) {
            SectionTitle("Processing")
            Card(padding: Theme.Spacing.m) {
                VStack(spacing: Theme.Spacing.m) {
                    ForEach(pipeline.jobs) { job in
                        ProcessingRow(job: job)
                    }
                }
            }
        }
    }

    private var highlightsSection: some View {
        VStack(spacing: Theme.Spacing.m) {
            SectionTitle("Today's highlights")
            Card(padding: Theme.Spacing.m) {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    ForEach(highlights) { highlight in
                        NavigationLink(value: RecordingRoute(recordingID: highlight.recording.id)) {
                            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                                Image(systemName: "checkmark.seal")
                                    .foregroundStyle(Theme.Palette.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(highlight.text).font(.subheadline).foregroundStyle(Theme.Palette.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Text(highlight.recording.title).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func recordingsSection(_ title: String, _ recordings: [Recording]) -> some View {
        if !recordings.isEmpty {
            VStack(spacing: Theme.Spacing.m) {
                SectionTitle(title)
                Card(padding: Theme.Spacing.m) {
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(recordings) { recording in
                            NavigationLink(value: RecordingRoute(recordingID: recording.id)) {
                                RecordingRow(recording: recording, job: pipeline.job(for: recording.id))
                            }
                            .buttonStyle(.plain)
                            if recording.id != recordings.last?.id { Divider().overlay(Theme.Palette.stroke) }
                        }
                    }
                }
            }
        }
    }

    private func reload() {
        let all = (try? environment.store.recordings(limit: 30)) ?? []
        let calendar = Calendar.current
        today = all.filter { calendar.isDateInToday($0.createdAt) }
        recent = Array(all.filter { !calendar.isDateInToday($0.createdAt) }.prefix(6))
        var found: [Highlight] = []
        for recording in today {
            guard let summary = try? environment.store.summary(recordingID: recording.id) else { continue }
            for decision in summary.decisions.prefix(2) { found.append(Highlight(text: decision, recording: recording)) }
            if summary.decisions.isEmpty, let point = summary.keyPoints.first {
                found.append(Highlight(text: point, recording: recording))
            }
        }
        highlights = Array(found.prefix(5))
    }
}

struct SettingsRoute: Hashable {}

struct ProcessingRow: View {
    let job: ProcessingPipeline.Job
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline

    var body: some View {
        let recording = try? environment.store.recording(id: job.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(recording?.title ?? "Recording").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Button {
                    pipeline.cancel(recordingID: job.id)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Palette.textSecondary)
                }
                .accessibilityLabel("Cancel processing")
            }
            switch job.stage {
            case .queued:
                Text("Waiting").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            case .transcribing:
                ProgressView(value: job.progress).tint(Theme.Palette.accent)
                HStack {
                    Text("Transcribing on device · \(Int(job.progress * 100))%")
                    Spacer()
                    if let recording { Text(pipeline.transcriptionEstimate(for: recording)).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            case .summarizing:
                ProgressView(value: job.progress).tint(Theme.Palette.accent)
                Text("Summarizing on device").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

/// Live recording screen.
struct RecordingView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var recorder: AudioRecorderService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @State private var tagText = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            HStack {
                Button { confirmDiscard = true } label: {
                    Image(systemName: "xmark").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Discard recording")
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(recorder.state == .recording ? Theme.Palette.danger : Theme.Palette.warning)
                        .frame(width: 9, height: 9)
                    Text(recorder.state == .recording ? "Recording" : "Paused").font(.headline)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .foregroundStyle(Theme.Palette.textPrimary)

            Text(Format.duration(recorder.elapsed))
                .font(.system(size: 54, weight: .light, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("Elapsed time \(Format.duration(recorder.elapsed))")

            TextField("Title", text: $recorder.title)
                .multilineTextAlignment(.center)
                .font(.title3)
                .submitLabel(.done)

            WaveformView(levels: recorder.levels, active: recorder.state == .recording)
                .frame(height: 130)

            if let notice = recorder.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.warning)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: Theme.Spacing.m) {
                Picker("Type", selection: $recorder.kind) {
                    Text("Meeting").tag(RecordingKind.meeting)
                    Text("Call").tag(RecordingKind.call)
                    Text("Note").tag(RecordingKind.note)
                }
                .pickerStyle(.segmented)

                TextField("Tags, separated by commas", text: $tagText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                    .onChange(of: tagText) { _, value in
                        recorder.tags = value.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }

                Text("AAC · \(recorder.quality.label) · about \(Int(recorder.quality.megabytesPerHour.rounded())) MB per hour · \(recorder.inputName)")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            HStack(spacing: 44) {
                Button {
                    recorder.state == .recording ? recorder.pause() : recorder.resume()
                } label: {
                    Image(systemName: recorder.state == .recording ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                        .background(Theme.Palette.surfaceRaised, in: Circle())
                }
                .accessibilityLabel(recorder.state == .recording ? "Pause" : "Resume")

                Button {
                    isSaving = true
                    Task {
                        await environment.finishRecording()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 84, height: 84)
                        .background(Theme.Palette.danger, in: Circle())
                }
                .disabled(isSaving)
                .accessibilityLabel("Stop and save")
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.bottom, Theme.Spacing.l)
        }
        .padding(Theme.Spacing.l)
        .background(Theme.Palette.background.ignoresSafeArea())
        .interactiveDismissDisabled()
        .onChange(of: recorder.state) { _, state in
            // The recorder stopped on its own (audio system reset, encoding error).
            if state == .idle, !isSaving {
                Task {
                    await environment.importFinishedCaptures()
                    dismiss()
                }
            }
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard recording", role: .destructive) {
                isSaving = true
                recorder.discard()
                dismiss()
            }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The audio recorded so far will be deleted.")
        }
    }
}
