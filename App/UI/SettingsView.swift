import SwiftUI
import PocketMindCore

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager

    var body: some View {
        List {
            Section {
                NavigationLink { ModelsView() } label: {
                    row("AI Models", "cpu", detail: modelSummary)
                }
                NavigationLink { StorageView() } label: {
                    row("Storage", "internaldrive", detail: "Recordings, models and free space")
                }
                NavigationLink { PrivacyView() } label: {
                    row("Privacy & Security", "lock.shield", detail: "\(AppLock.biometryName), encryption, data retention")
                }
            }

            Section("Recording") {
                Picker("Quality", selection: $settings.quality) {
                    ForEach(RecordingQuality.allCases, id: \.self) { quality in
                        Text("\(quality.label) · ~\(Int(quality.megabytesPerHour.rounded())) MB/h").tag(quality)
                    }
                }
                Picker("Default type", selection: $settings.defaultKind) {
                    Text("Meeting").tag(RecordingKind.meeting)
                    Text("Call").tag(RecordingKind.call)
                    Text("Note").tag(RecordingKind.note)
                }
            }

            Section {
                Picker("Transcription language", selection: $settings.transcriptionLanguage) {
                    Text("Detect automatically").tag("")
                    ForEach(SupportedLanguage.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Toggle("Transcribe new recordings", isOn: $settings.autoTranscribe)
                Toggle("Summarize after transcribing", isOn: $settings.autoSummarize)
                Toggle("Keep screen on while processing", isOn: $settings.keepAwakeWhileProcessing)
                Toggle("Notify when processing finishes", isOn: $settings.notifyWhenProcessed)
            } header: {
                Text("Languages & processing")
            } footer: {
                Text("Tuned for English, Arabic, Ukrainian, Dutch and French. Processing uses the graphics processor, which iOS only allows while the app is open, so keeping the screen on finishes long recordings sooner. Notifications never show recording titles or content.")
            }

            Section {
                NavigationLink { TemplatesView() } label: { row("Summary templates", "doc.text", detail: nil) }
                NavigationLink { ActionButtonHelpView() } label: {
                    row("Action Button", "button.programmable", detail: "Start recording with one press")
                }
                NavigationLink { AboutView() } label: { row("About", "info.circle", detail: nil) }
            }
        }
        .screenBackground()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modelSummary: String {
        let speech = models.activeWhisperModel?.name ?? "no speech model"
        let language = models.activeLanguageModel?.name ?? "no language model"
        return "\(speech), \(language)"
    }

    private func row(_ title: String, _ icon: String, detail: String?) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Models

struct ModelsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @EnvironmentObject private var pipeline: ProcessingPipeline

    @State private var confirmDownload: ModelDescriptor?
    @State private var benchmarking: String?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("Models are downloaded once from huggingface.co, checked against a known SHA-256 fingerprint, and then run entirely on this iPhone. Downloading a model is the only time PocketMind uses the network; your audio and text are never sent anywhere.")
                    .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                LabeledContent("Free storage", value: Format.bytes(environment.vault.freeDiskSpace))
                LabeledContent("Device memory", value: Format.bytes(Int64(ProcessInfo.processInfo.physicalMemory)))
                Toggle("Download over Wi-Fi only", isOn: $settings.wifiOnlyDownloads)
            }
            Section {
                ForEach(ModelCatalog.whisper) { modelRow($0, selection: $settings.whisperModelID) }
            } header: {
                Text("Speech to text (Whisper)")
            } footer: {
                Text("Larger models are more accurate, especially for Arabic and Ukrainian, but slower and heavier on the battery. Run a benchmark to see real speed on this device.")
            }
            Section {
                ForEach(ModelCatalog.languageModels) { modelRow($0, selection: $settings.languageModelID) }
            } header: {
                Text("Summaries and memory (language model)")
            } footer: {
                Text("Optional. Without a language model, summaries quote sentences from the transcript and Memory lists matching passages.")
            }
        }
        .screenBackground()
        .navigationTitle("AI Models")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: pipeline.revision) { models.refresh() }
        .confirmationDialog(
            "Download \(confirmDownload?.name ?? "")?",
            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } }),
            titleVisibility: .visible
        ) {
            Button("Download \(confirmDownload?.sizeDescription ?? "")") {
                if let model = confirmDownload { models.download(model) }
                confirmDownload = nil
            }
            Button("Cancel", role: .cancel) { confirmDownload = nil }
        } message: {
            Text("This connects to huggingface.co to fetch the model file (\(confirmDownload?.sizeDescription ?? "")). Nothing from your recordings is sent. License: \(confirmDownload?.license ?? "").")
        }
        .alert("Benchmark", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelDescriptor, selection: Binding<String>) -> some View {
        let state = models.state(of: model)
        let compatibility = models.compatibility(of: model)
        let benchmark = try? environment.store.benchmark(modelID: model.id)

        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.subheadline.weight(.semibold))
                    Text("\(model.sizeDescription) · Speed: \(model.speed) · Accuracy: \(model.accuracy)")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                if state == .installed, selection.wrappedValue == model.id {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.success)
                }
            }
            Text(model.notes).font(.caption).foregroundStyle(Theme.Palette.textSecondary)

            switch compatibility {
            case .compatible: EmptyView()
            case .warning(let text): Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.warning)
            case .incompatible(let text): Label(text, systemImage: "xmark.octagon").font(.caption).foregroundStyle(Theme.Palette.danger)
            }

            if let benchmark {
                Text("Measured on this iPhone: \(benchmark.detail)")
                    .font(.caption).foregroundStyle(Theme.Palette.accent)
            }

            switch state {
            case .notInstalled:
                Button("Download") { confirmDownload = model }
                    .disabled(!compatibility.isInstallable)
            case .downloading(let progress):
                ProgressView(value: progress).tint(Theme.Palette.accent)
                HStack {
                    Text("Downloading \(Int(progress * 100))%").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    Spacer()
                    Button("Cancel", role: .destructive) { models.cancelDownload(model) }.font(.caption)
                }
            case .verifying:
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView()
                    Text("Verifying integrity (SHA-256)…").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            case .installed:
                HStack(spacing: Theme.Spacing.l) {
                    if selection.wrappedValue != model.id {
                        Button("Use") { selection.wrappedValue = model.id }
                    }
                    Button(benchmarking == model.id ? "Measuring…" : "Benchmark") { runBenchmark(model) }
                        .disabled(benchmarking != nil || pipeline.isBusy)
                    Spacer()
                    Button("Delete", role: .destructive) {
                        Task {
                            await pipeline.engines.unloadAll()
                            models.delete(model)
                        }
                    }
                    .disabled(pipeline.isBusy)
                }
                .font(.footnote.weight(.semibold))
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.danger)
                Button("Try again") { confirmDownload = model }.disabled(!compatibility.isInstallable)
            }
        }
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
    }

    private func runBenchmark(_ model: ModelDescriptor) {
        benchmarking = model.id
        Task {
            defer { benchmarking = nil }
            do {
                if model.kind == .whisper {
                    guard let sample = try environment.store.recordings(limit: 20).first(where: { $0.duration >= 10 }) else {
                        message = "Make a recording of at least 10 seconds first. The benchmark transcribes its first 30 seconds so the result reflects real speech on this device."
                        return
                    }
                    let result = try await pipeline.benchmarkWhisper(model, using: sample)
                    message = "\(model.name): \(result.detail). One hour of audio should take \(ProcessingEstimator.describe(seconds: 3600 * result.rate))."
                } else {
                    let result = try await pipeline.benchmarkLanguageModel(model)
                    message = "\(model.name): \(result.detail)."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var models: ModelManager
    @State private var stats: StorageStats?
    @State private var audioBytes: Int64 = 0
    @State private var databaseBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0

    var body: some View {
        List {
            Section("On this iPhone") {
                LabeledContent("Encrypted audio", value: Format.bytes(audioBytes))
                LabeledContent("Transcripts, summaries, tasks", value: Format.bytes(databaseBytes))
                LabeledContent("AI models", value: Format.bytes(modelBytes))
                LabeledContent("Free space", value: "\(Format.bytes(environment.vault.freeDiskSpace)) of \(Format.bytes(environment.vault.totalDiskSpace))")
            }
            if let stats {
                Section("Library") {
                    LabeledContent("Recordings", value: "\(stats.recordings)")
                    LabeledContent("Total recorded time", value: Format.shortDuration(stats.totalDuration))
                    LabeledContent("Recently deleted", value: "\(stats.trashed)")
                    LabeledContent("Transcript lines", value: "\(stats.segments)")
                    LabeledContent("Tasks", value: "\(stats.tasks)")
                }
            }
        }
        .screenBackground()
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.revision) {
            stats = try? environment.store.stats()
            let vault = environment.vault
            let sizes = await Task.detached {
                (Vault.directorySize(vault.audioDirectory), Vault.directorySize(vault.databaseDirectory),
                 Vault.directorySize(vault.modelsDirectory))
            }.value
            (audioBytes, databaseBytes, modelBytes) = sizes
        }
    }
}

// MARK: - Privacy

struct PrivacyView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var events: [NetworkEvent] = []
    @State private var stats: StorageStats?
    @State private var confirmErase = false

    var body: some View {
        List {
            Section {
                Toggle("Require \(AppLock.biometryName) to open", isOn: $settings.appLockEnabled)
                if !AppLock.deviceCanAuthenticate {
                    Label("This iPhone has no passcode. Without one, the app lock cannot work and iOS does not encrypt your files. Set a passcode in the Settings app.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Theme.Palette.warning)
                }
            } header: {
                Text("App lock")
            } footer: {
                Text("PocketMind locks whenever it leaves the screen, and hides its contents in the app switcher.")
            }

            Section {
                dashboardRow("Recordings", "\(stats?.recordings ?? 0) stored, AES-256-GCM encrypted", "lock.fill")
                dashboardRow("Transcripts and summaries", "In a database iOS encrypts whenever the phone is locked", "lock.fill")
                dashboardRow("Encryption key", "In the Keychain, this device only, never backed up", "key.fill")
                dashboardRow("Backups and iCloud", "Excluded: nothing from PocketMind is in iCloud or computer backups", "icloud.slash")
                dashboardRow("Accounts, analytics, ads", "None. There is no account and no tracking code in the app", "hand.raised.fill")
                dashboardRow("Permissions", "Microphone (required), Face ID and notifications (optional)", "checkmark.shield")
            } header: {
                Text("What is stored, and how")
            }

            Section {
                if events.isEmpty {
                    Label("PocketMind has made no network requests on this device.", systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(Theme.Palette.success)
                } else {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.purpose).font(.subheadline)
                            Text("\(event.host) · \(Format.dateTime(event.at))" + (event.bytes > 0 ? " · \(Format.bytes(event.bytes)) received" : ""))
                                .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            } header: {
                Text("Network activity")
            } footer: {
                Text("Every request the app makes is listed here. The only requests it can make are model downloads you start yourself. This log covers PocketMind's own code; it cannot see connections made by iOS itself.")
            }

            Section {
                Picker("Keep deleted recordings for", selection: $settings.trashDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("Automatically delete recordings", selection: $settings.retentionDays) {
                    Text("Never").tag(0)
                    Text("After 30 days").tag(30)
                    Text("After 90 days").tag(90)
                    Text("After 1 year").tag(365)
                }
            } header: {
                Text("Data retention")
            } footer: {
                Text("Automatic deletion skips favorites. Deleted recordings are removed together with their transcript, summary, tasks, search index entries and audio.")
            }

            Section {
                Button("Erase all recordings and data", role: .destructive) { confirmErase = true }
            } footer: {
                Text("Deletes every recording, transcript, summary and task, and destroys the encryption key. Installed AI models are kept.")
            }
        }
        .screenBackground()
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: environment.revision) {
            events = (try? environment.store.networkEvents()) ?? []
            stats = try? environment.store.stats()
        }
        .onChange(of: settings.retentionDays) { _, _ in environment.applyRetention() }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase all data", role: .destructive) { Task { await environment.eraseEverything() } }
        } message: {
            Text("This permanently deletes all recordings, transcripts, summaries and tasks. It cannot be undone.")
        }
    }

    private func dashboardRow(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Image(systemName: icon).foregroundStyle(Theme.Palette.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Templates, Action Button, About

struct TemplatesView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var templates: [SummaryTemplate] = []
    @State private var editing: SummaryTemplate?

    var body: some View {
        List {
            Section("Built in") {
                ForEach(SummaryTemplate.builtIns) { template in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.name)
                        Text(template.instructions).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            Section {
                ForEach(templates) { template in
                    Button { editing = template } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).foregroundStyle(Theme.Palette.textPrimary)
                            Text(template.instructions).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { try? environment.store.deleteTemplate(id: templates[index].id) }
                    reload()
                }
                Button("New template") { editing = SummaryTemplate(name: "", instructions: "") }
            } header: {
                Text("Yours")
            } footer: {
                Text("A template adds guidance to the summary request, for example “List every risk that was raised”. Templates need an installed language model.")
            }
        }
        .screenBackground()
        .navigationTitle("Summary Templates")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { saved in
                try? environment.store.save(saved)
                reload()
            }
        }
        .task { reload() }
    }

    private func reload() {
        templates = (try? environment.store.customTemplates()) ?? []
        environment.touch()
    }
}

struct TemplateEditor: View {
    @State var template: SummaryTemplate
    let save: (SummaryTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $template.name)
                Section("Guidance for the summary") {
                    TextEditor(text: $template.instructions).frame(minHeight: 140)
                }
            }
            .navigationTitle("Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(template)
                        dismiss()
                    }
                    .disabled(template.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

struct ActionButtonHelpView: View {
    var body: some View {
        List {
            Section {
                step(1, "Open the iPhone Settings app and choose Action Button.")
                step(2, "Swipe to Shortcut and tap Choose a Shortcut.")
                step(3, "Pick PocketMind, then Start Recording.")
                step(4, "Press and hold the Action Button: PocketMind opens and starts recording.")
            } footer: {
                Text("The same action is available in the Shortcuts app and through Siri (“Start recording in PocketMind”). PocketMind always comes to the screen when it starts recording, and iOS shows its microphone indicator for as long as it records. If the app lock is on, recording starts after you unlock.")
            }
        }
        .screenBackground()
        .navigationTitle("Action Button")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .frame(width: 24, height: 24)
                .background(Theme.Palette.accentSoft, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: version)
                LabeledContent("Speech recognition", value: "whisper.cpp 1.9.5")
                LabeledContent("Language model runtime", value: "llama.cpp b12317")
            }
            Section("Good to know") {
                Text("Record only with the knowledge and consent of the people you are recording. Laws on recording conversations differ between countries and regions.")
                Text("Transcripts and summaries are produced by small on-device models and contain mistakes. Check important details against the audio.")
            }
            .font(.footnote)
            Section("Open-source components") {
                Text("whisper.cpp and llama.cpp (MIT License, © The ggml authors). Model files are downloaded separately under their own licenses, shown before each download.")
                    .font(.footnote)
            }
        }
        .screenBackground()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
