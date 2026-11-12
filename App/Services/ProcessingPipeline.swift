import BackgroundTasks
import Foundation
import LlamaBridge
import PocketMindCore
import UIKit
import UserNotifications
import WhisperBridge

/// Loads at most one large model at a time. Asking for the language model releases
/// Whisper first (and the other way round), so the two never compete for memory.
actor EngineHost {
    private var whisper: WhisperEngine?
    private var llama: LlamaEngine?

    func whisperEngine(model: ModelDescriptor, path: String, useGPU: Bool) throws -> WhisperEngine {
        if let whisper, whisper.modelID == model.id, whisper.usesGPU == useGPU { return whisper }
        whisper = nil
        llama = nil
        let engine = try WhisperEngine(modelPath: path, modelID: model.id, useGPU: useGPU)
        whisper = engine
        return engine
    }

    func languageEngine(model: ModelDescriptor, path: String, useGPU: Bool) throws -> LlamaEngine {
        if let llama, llama.modelID == model.id, llama.usesGPU == useGPU { return llama }
        llama = nil
        whisper = nil
        let engine = try LlamaEngine(modelPath: path, modelID: model.id, contextTokens: 4096, useGPU: useGPU)
        llama = engine
        return engine
    }

    /// Frees all model memory (memory warning, app going to the background, model deleted).
    func unloadAll() {
        whisper = nil
        llama = nil
    }
}

/// Thread-safe cancellation flag polled by the inference engines.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Runs transcription and summarisation jobs one at a time, off the main thread.
@MainActor
final class ProcessingPipeline: ObservableObject {
    enum Stage: Equatable { case queued, transcribing, summarizing }

    struct Job: Identifiable, Equatable {
        let id: String              // recording id
        var stage: Stage
        var progress: Double
        var transcribe: Bool
        var summarize: Bool
        var templateID: String?
        var language: String?
        var startedAt: Date?
    }

    /// Transcription progress kept in memory so that work interrupted by the app going to
    /// the background resumes at the next audio window instead of starting over.
    private struct Checkpoint: Sendable {
        var segments: [RawSegment] = []
        var offset: Double = 0
        var language: String?
    }

    @Published private(set) var jobs: [Job] = []
    /// Bumped whenever stored data changed, so views reload.
    @Published private(set) var revision = 0

    nonisolated static var backgroundTaskIdentifier: String { (Bundle.main.bundleIdentifier ?? "app.pocketmind.PocketMind") + ".processing" }
    nonisolated private static let windowSeconds: Double = 300

    private let store: Store
    private let vault: Vault
    private let models: ModelManager
    private let settings: AppSettings
    let engines = EngineHost()

    private var worker: Task<Void, Never>?
    private var currentFlag: CancellationFlag?
    private var checkpoints: [String: Checkpoint] = [:]
    private var suspended = false
    /// True while running inside a background task, where GPU work is not allowed.
    private var cpuOnly = false

    init(store: Store, vault: Vault, models: ModelManager, settings: AppSettings) {
        self.store = store
        self.vault = vault
        self.models = models
        self.settings = settings
    }

    func job(for recordingID: String) -> Job? { jobs.first { $0.id == recordingID } }
    var isBusy: Bool { !jobs.isEmpty }

    // MARK: Queue

    func enqueue(recordingID: String, transcribe: Bool, summarize: Bool, templateID: String? = nil, language: String? = nil) {
        guard transcribe || summarize else { return }
        if let index = jobs.firstIndex(where: { $0.id == recordingID }) {
            jobs[index].transcribe = jobs[index].transcribe || transcribe
            jobs[index].summarize = jobs[index].summarize || summarize
            if let templateID { jobs[index].templateID = templateID }
        } else {
            jobs.append(Job(id: recordingID, stage: .queued, progress: 0, transcribe: transcribe, summarize: summarize,
                            templateID: templateID, language: language, startedAt: nil))
        }
        startWorkerIfNeeded()
    }

    /// Queues everything a new recording needs, according to the user's settings.
    func enqueueAutomaticProcessing(for recording: Recording) {
        let canTranscribe = settings.autoTranscribe && models.activeWhisperModel != nil
        enqueue(recordingID: recording.id, transcribe: canTranscribe, summarize: canTranscribe && settings.autoSummarize)
    }

    /// Re-queues recordings whose processing never finished (app quit, phone restarted).
    func resumeUnfinishedWork() {
        guard let recordings = try? store.recordings() else { return }
        for recording in recordings where job(for: recording.id) == nil {
            switch recording.status {
            case .transcribing:
                try? store.setStatus(.recorded, for: recording.id)
                if models.activeWhisperModel != nil {
                    enqueue(recordingID: recording.id, transcribe: true, summarize: settings.autoSummarize)
                }
            case .summarizing:
                try? store.setStatus(.transcribed, for: recording.id)
                enqueue(recordingID: recording.id, transcribe: false, summarize: true)
            case .recorded where settings.autoTranscribe && models.activeWhisperModel != nil:
                enqueue(recordingID: recording.id, transcribe: true, summarize: settings.autoSummarize)
            default:
                break
            }
        }
        revision += 1
    }

    func cancel(recordingID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == recordingID }) else { return }
        if index == 0, jobs[0].stage != .queued {
            currentFlag?.cancel() // the worker removes the job and restores the status
        } else {
            jobs.remove(at: index)
        }
        checkpoints[recordingID] = nil
    }

    // MARK: App lifecycle

    /// Called when the app leaves the foreground. iOS forbids GPU work in the background,
    /// so the running job is stopped at the next safe point and kept in the queue.
    func suspendForBackground() {
        guard !suspended else { return }
        suspended = true
        currentFlag?.cancel()
        if !jobs.isEmpty { scheduleBackgroundProcessing() }
        Task { await engines.unloadAll() }
    }

    func resumeFromForeground() {
        suspended = false
        cpuOnly = false
        startWorkerIfNeeded()
    }

    func handleMemoryWarning() {
        guard worker == nil else { return }
        Task { await engines.unloadAll() }
    }

    // MARK: Background tasks

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor [weak self] in self?.runInBackground(task) }
        }
    }

    private func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true // model inference is heavy; do it on the charger
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runInBackground(_ task: BGProcessingTask) {
        // Transcripts live under "complete" file protection and cannot be opened while the
        // phone is locked. If it is, try again later rather than fail every job.
        guard UIApplication.shared.isProtectedDataAvailable, !jobs.isEmpty else {
            if !jobs.isEmpty { scheduleBackgroundProcessing() }
            task.setTaskCompleted(success: true)
            return
        }
        cpuOnly = true
        suspended = false
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.suspended = true
                self?.currentFlag?.cancel()
            }
        }
        startWorkerIfNeeded()
        let running = worker
        Task { @MainActor [weak self] in
            await running?.value
            guard let self else { return }
            if !self.jobs.isEmpty { self.scheduleBackgroundProcessing() }
            self.cpuOnly = false
            task.setTaskCompleted(success: self.jobs.isEmpty)
        }
    }

    // MARK: Worker

    private func startWorkerIfNeeded() {
        guard worker == nil, !suspended, !jobs.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        updateIdleTimer()
        defer { updateIdleTimer(forceOff: true) }

        while let job = jobs.first, !suspended {
            let flag = CancellationFlag()
            currentFlag = flag
            var completed = false
            do {
                try await run(job, flag: flag)
                completed = true
            } catch EngineError.cancelled {
                restoreStatusAfterCancel(recordingID: job.id)
                // Suspended for the background: keep the job. Cancelled by the user: drop it.
                if suspended {
                    if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                        jobs[index].stage = .queued
                        jobs[index].progress = 0
                    }
                    break
                }
            } catch {
                try? store.setStatus(.failed, error: error.localizedDescription, for: job.id)
            }
            currentFlag = nil
            checkpoints[job.id] = nil
            jobs.removeAll { $0.id == job.id }
            revision += 1
            if completed { await notifyFinished() }
        }
        currentFlag = nil
        revision += 1
        // Do not keep gigabytes of model weights resident once the queue is empty.
        if jobs.isEmpty { await engines.unloadAll() }
    }

    private func restoreStatusAfterCancel(recordingID: String) {
        guard let recording = try? store.recording(id: recordingID) else { return }
        switch recording.status {
        case .transcribing: try? store.setStatus(.recorded, for: recordingID)
        case .summarizing: try? store.setStatus(.transcribed, for: recordingID)
        default: break
        }
        revision += 1
    }

    private func update(_ recordingID: String, stage: Stage? = nil, progress: Double? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == recordingID }) else { return }
        if let stage {
            jobs[index].stage = stage
            jobs[index].startedAt = Date()
        }
        if let progress { jobs[index].progress = max(0, min(1, progress)) }
    }

    private func run(_ job: Job, flag: CancellationFlag) async throws {
        guard var recording = try store.recording(id: job.id), recording.deletedAt == nil else { return }
        let useGPU = !cpuOnly && UIApplication.shared.applicationState != .background

        if job.transcribe {
            guard let model = models.activeWhisperModel else { throw EngineError.modelNotInstalled }
            update(job.id, stage: .transcribing, progress: 0)
            try store.setStatus(.transcribing, for: job.id)
            revision += 1

            let started = Date()
            let language = job.language ?? (settings.transcriptionLanguage.isEmpty ? nil : settings.transcriptionLanguage)
            let output = try await transcribe(recording, model: model, language: language, useGPU: useGPU, flag: flag)
            // Writing and indexing a long transcript is kept off the main thread.
            let backgroundStore = self.store
            let transcribedID = job.id
            try await Task.detached(priority: .userInitiated) {
                try backgroundStore.replaceTranscript(recordingID: transcribedID, segments: output.segments, language: output.language)
            }.value

            recording = try store.recording(id: job.id) ?? recording
            recording.status = .transcribed
            recording.modelUsed = model.id
            recording.errorMessage = nil
            try store.save(recording)

            // Every real transcription doubles as a measurement for time estimates.
            let seconds = Date().timeIntervalSince(started)
            if recording.duration > 20, checkpointWasFresh(job.id) {
                try? store.save(BenchmarkResult(
                    modelID: model.id, rate: seconds / recording.duration,
                    detail: "Measured on a \(Format.shortDuration(recording.duration)) recording"))
            }
            checkpoints[job.id] = nil
            revision += 1
        }

        if job.summarize {
            let segments = try store.segments(recordingID: job.id)
            guard !segments.isEmpty else {
                try store.setStatus(.ready, for: job.id)
                return
            }
            update(job.id, stage: .summarizing, progress: 0)
            try store.setStatus(.summarizing, for: job.id)
            revision += 1

            var engine: LlamaEngine?
            if let model = models.activeLanguageModel {
                let path = models.fileURL(for: model).path
                engine = try await engines.languageEngine(model: model, path: path, useGPU: useGPU)
            }
            let template = try store.template(id: job.templateID ?? defaultTemplateID(for: recording.kind))
            let speakers = try store.speakers(recordingID: job.id)
            let recordingID = job.id
            let summary = try await Summarizer(llm: engine).summarize(
                segments: segments, speakers: speakers, title: recording.title, template: template,
                progress: { [weak self] value in
                    Task { @MainActor [weak self] in self?.update(recordingID, progress: value) }
                },
                isCancelled: { flag.isCancelled })

            try store.save(summary, recordingID: job.id)
            try store.replaceExtractedTasks(
                recordingID: job.id,
                with: TaskExtractor.tasks(from: summary, recording: recording, segments: segments))

            recording = try store.recording(id: job.id) ?? recording
            // Adopt the generated title only if the user never named the recording.
            if recording.title.hasPrefix("Recording "), summary.isFromLanguageModel, !summary.title.isEmpty {
                recording.title = summary.title
            }
            recording.status = .ready
            recording.errorMessage = nil
            try store.save(recording)
        } else if job.transcribe {
            // Transcribed without a summary step.
            try store.setStatus(.transcribed, for: job.id)
        }
    }

    private var freshCheckpoints: Set<String> = []
    private func checkpointWasFresh(_ recordingID: String) -> Bool { freshCheckpoints.remove(recordingID) != nil }

    private func defaultTemplateID(for kind: RecordingKind) -> String {
        switch kind {
        case .meeting, .imported: SummaryTemplate.meeting.id
        case .call: SummaryTemplate.call.id
        case .note: SummaryTemplate.note.id
        }
    }

    /// Transcribes a recording window by window. Memory stays bounded for recordings of
    /// any length, and each window boundary is placed in a quiet moment.
    private func transcribe(_ recording: Recording, model: ModelDescriptor, language: String?, useGPU: Bool,
                            flag: CancellationFlag) async throws -> TranscriptionOutput {
        let engine = try await engines.whisperEngine(model: model, path: models.fileURL(for: model).path, useGPU: useGPU)
        let recordingID = recording.id
        let start = checkpoints[recordingID] ?? Checkpoint(language: language)
        if start.offset == 0 { freshCheckpoints.insert(recordingID) }

        let finished = try await Self.transcribeWindows(
            vault: vault, recording: recording, engine: engine, start: start, flag: flag,
            onProgress: { [weak self] value in
                Task { @MainActor [weak self] in self?.update(recordingID, progress: value) }
            },
            onCheckpoint: { [weak self] checkpoint in
                Task { @MainActor [weak self] in self?.checkpoints[recordingID] = checkpoint }
            })
        return TranscriptionOutput(segments: finished.segments, language: finished.language)
    }

    /// The decoding and inference loop. Deliberately not on the main actor: decrypting and
    /// resampling several minutes of audio must not stall the interface.
    nonisolated private static func transcribeWindows(
        vault: Vault, recording: Recording, engine: WhisperEngine, start: Checkpoint, flag: CancellationFlag,
        onProgress: @escaping @Sendable (Double) -> Void,
        onCheckpoint: @escaping @Sendable (Checkpoint) -> Void
    ) async throws -> Checkpoint {
        try await vault.withDecryptedAudio(for: recording) { url in
            var checkpoint = start
            let reader = try AudioWindowReader(url: url)
            let total = max(reader.duration, 0.1)

            while checkpoint.offset < total - 0.05 {
                if flag.isCancelled { throw EngineError.cancelled }
                // Each window starts exactly where the previous one was cut.
                reader.seek(toSeconds: checkpoint.offset)
                let buffer = try reader.read(seconds: windowSeconds)
                guard !buffer.isEmpty else { break }

                let cut = reader.isAtEnd ? buffer.count : AudioWindowing.splitIndex(samples: buffer)
                let windowStart = checkpoint.offset
                let windowLength = Double(cut) / Double(AudioWindowReader.sampleRate)
                let output = try await engine.transcribe(
                    samples: Array(buffer[..<cut]), language: checkpoint.language,
                    progress: { value in onProgress((windowStart + value * windowLength) / total) },
                    isCancelled: { flag.isCancelled })

                checkpoint.segments += output.segments.map {
                    RawSegment(start: $0.start + windowStart, end: $0.end + windowStart, text: $0.text)
                }
                // Detect the language once, on the first window, and keep it for the rest.
                if checkpoint.language == nil { checkpoint.language = output.language }
                checkpoint.offset += windowLength
                onCheckpoint(checkpoint)
                if cut == buffer.count, reader.isAtEnd { break }
            }
            return checkpoint
        }
    }

    // MARK: Benchmarks

    /// Measures a Whisper model on the first 30 seconds of a real recording and stores the
    /// result (processing seconds per second of audio).
    func benchmarkWhisper(_ model: ModelDescriptor, using recording: Recording) async throws -> BenchmarkResult {
        guard worker == nil else { throw EngineError.inferenceFailed("Wait for current processing to finish first.") }
        let engine = try await engines.whisperEngine(model: model, path: models.fileURL(for: model).path, useGPU: true)
        let samples: [Float] = try await vault.withDecryptedAudio(for: recording) { url in
            try AudioWindowReader(url: url).read(seconds: 30)
        }
        guard samples.count >= AudioWindowReader.sampleRate * 5 else {
            throw EngineError.inferenceFailed("The recording is too short to benchmark with (need at least 5 s).")
        }
        let audioSeconds = Double(samples.count) / Double(AudioWindowReader.sampleRate)
        let started = Date()
        _ = try await engine.transcribe(samples: samples, language: nil, progress: { _ in }, isCancelled: { false })
        let elapsed = Date().timeIntervalSince(started)
        let result = BenchmarkResult(
            modelID: model.id, rate: elapsed / audioSeconds,
            detail: String(format: "%.1f s to transcribe %.0f s of audio", elapsed, audioSeconds))
        try store.save(result)
        revision += 1
        return result
    }

    /// Measures a language model by generating a fixed number of tokens (seconds per token).
    func benchmarkLanguageModel(_ model: ModelDescriptor) async throws -> BenchmarkResult {
        guard worker == nil else { throw EngineError.inferenceFailed("Wait for current processing to finish first.") }
        let engine = try await engines.languageEngine(model: model, path: models.fileURL(for: model).path, useGPU: true)
        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        let started = Date()
        _ = try await engine.generate(
            messages: [ChatMessage(.user, "Write a short paragraph about how to run an effective team meeting.")],
            options: GenerationOptions(maxTokens: 96, temperature: 0)) { piece in
                if !piece.isEmpty { counter.count += 1 }
                return true
            }
        let elapsed = Date().timeIntervalSince(started)
        let tokens = max(1, counter.count)
        let result = BenchmarkResult(
            modelID: model.id, rate: elapsed / Double(tokens),
            detail: String(format: "%.1f tokens per second (%d tokens in %.1f s, including prompt)", Double(tokens) / elapsed, tokens, elapsed))
        try store.save(result)
        revision += 1
        return result
    }

    /// Estimated transcription time for a recording, from measurements on this device.
    func transcriptionEstimate(for recording: Recording) -> String {
        let rate = models.activeWhisperModel.flatMap { try? store.benchmark(modelID: $0.id) }?.rate
        return ProcessingEstimator.describe(
            seconds: ProcessingEstimator.transcriptionSeconds(audioDuration: recording.duration, realTimeFactor: rate))
    }

    // MARK: Side effects

    private func updateIdleTimer(forceOff: Bool = false) {
        // Keeping the screen on keeps the app in the foreground, where the GPU is available.
        UIApplication.shared.isIdleTimerDisabled = !forceOff && settings.keepAwakeWhileProcessing && !jobs.isEmpty && !cpuOnly
    }

    private func notifyFinished() async {
        guard settings.notifyWhenProcessed, UIApplication.shared.applicationState != .active else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        // Deliberately generic: recording titles and contents never appear on the lock screen.
        content.title = "PocketMind"
        content.body = "A recording has finished processing."
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
