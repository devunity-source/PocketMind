import AVFoundation
import Foundation
import PocketMindCore
import UIKit

/// Everything the interface needs, created once at launch.
@MainActor
final class AppEnvironment: ObservableObject {
    let vault: Vault
    let store: Store
    let settings: AppSettings
    let recorder: AudioRecorderService
    let player: AudioPlayerService
    let models: ModelManager
    let pipeline: ProcessingPipeline
    let lock: AppLock

    /// Bumped whenever library data changes outside the pipeline, so views reload.
    @Published private(set) var revision = 0
    @Published var banner: String?

    init() throws {
        let vault = try Vault()
        let store = try Store(path: vault.databaseURL.path)
        let settings = AppSettings()
        self.vault = vault
        self.store = store
        self.settings = settings
        recorder = AudioRecorderService(captureDirectory: vault.captureDirectory)
        player = AudioPlayerService(vault: vault)
        models = ModelManager(directory: vault.modelsDirectory, store: store, settings: settings,
                              freeDiskSpace: { vault.freeDiskSpace })
        pipeline = ProcessingPipeline(store: store, vault: vault, models: models, settings: settings)
        lock = AppLock(enabled: settings.appLockEnabled)
        pipeline.registerBackgroundTask()
    }

    func touch() { revision += 1 }

    // MARK: Launch and lifecycle

    /// Run once the interface is up and the device is unlocked.
    func didBecomeActive() async {
        await importFinishedCaptures()
        applyRetention()
        pipeline.resumeFromForeground()
        pipeline.resumeUnfinishedWork()
    }

    func didEnterBackground() {
        if settings.appLockEnabled { lock.lock() }
        // Playback data is decrypted audio held in memory; drop it when leaving.
        if !player.isPlaying { player.unload() }
        pipeline.suspendForBackground()
    }

    // MARK: Recording

    func startRecording() async {
        guard !recorder.isActive else { return }
        player.pause()
        let title = "Recording " + Date().formatted(.dateTime.month(.abbreviated).day().hour().minute())
        do {
            try await recorder.start(title: title, kind: settings.defaultKind, quality: settings.quality,
                                     freeDiskSpace: vault.freeDiskSpace)
        } catch {
            banner = error.localizedDescription
        }
    }

    /// Stops the recorder, moves the capture into the encrypted library and queues processing.
    @discardableResult
    func finishRecording() async -> Recording? {
        recorder.stop()
        return await importFinishedCaptures().last
    }

    /// Turns every finished capture in the capture directory into a library recording:
    /// measure, encrypt, insert, delete the plaintext. Called after a normal stop and at
    /// launch, where it recovers recordings interrupted by a crash, a restart or the
    /// phone locking before the capture could be sealed.
    @discardableResult
    func importFinishedCaptures() async -> [Recording] {
        guard UIApplication.shared.isProtectedDataAvailable else { return [] }
        let directory = vault.captureDirectory
        let vault = self.vault
        let store = self.store
        let activeID = recorder.isActive ? recorder.activeRecordingID : nil

        let (imported, unreadable) = await Task.detached(priority: .userInitiated) { () -> ([Recording], Int) in
            var imported: [Recording] = []
            var unreadable = 0
            for journal in RecoveryJournal.pending(in: directory) where journal.recordingID != activeID {
                let source = directory.appendingPathComponent(journal.audioFileName)
                defer { RecoveryJournal.remove(recordingID: journal.recordingID, from: directory) }
                guard FileManager.default.fileExists(atPath: source.path) else { continue }

                let duration = AudioWindowReader.duration(of: source)
                guard duration > 0.3 else {
                    // An .m4a that was never finalised (the app was killed mid-recording)
                    // has no index and cannot be read back.
                    if ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0) > 4_096 {
                        unreadable += 1
                    }
                    try? FileManager.default.removeItem(at: source)
                    continue
                }
                do {
                    let sealed = try vault.sealAudio(at: source, recordingID: journal.recordingID)
                    let recording = Recording(
                        id: journal.recordingID, title: journal.title, createdAt: journal.startedAt, duration: duration,
                        fileName: sealed.fileName, fileSize: sealed.size, quality: journal.quality, kind: journal.kind,
                        tags: journal.tags, status: .recorded)
                    try store.save(recording)
                    imported.append(recording)
                } catch {
                    continue
                }
            }
            return (imported, unreadable)
        }.value

        if unreadable > 0 {
            banner = "\(unreadable) interrupted recording\(unreadable == 1 ? "" : "s") could not be recovered because the audio file was never completed."
        }
        for recording in imported { pipeline.enqueueAutomaticProcessing(for: recording) }
        if !imported.isEmpty { touch() }
        return imported
    }

    /// Imports an existing audio file chosen in the Files picker.
    func importAudioFile(at url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let vault = self.vault
        let store = self.store
        let title = url.deletingPathExtension().lastPathComponent
        let scratch = vault.scratchURL(named: url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: scratch)
            let recording = try await Task.detached(priority: .userInitiated) { () throws -> Recording in
                let duration = AudioWindowReader.duration(of: scratch)
                guard duration > 0 else {
                    try? FileManager.default.removeItem(at: scratch)
                    throw EngineError.inferenceFailed("This file is not audio PocketMind can read.")
                }
                let created = (try? scratch.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let id = UUID().uuidString
                let sealed = try vault.sealAudio(at: scratch, recordingID: id)
                let recording = Recording(id: id, title: title, createdAt: created, duration: duration,
                                          fileName: sealed.fileName, fileSize: sealed.size, kind: .imported, status: .recorded)
                try store.save(recording)
                return recording
            }.value
            pipeline.enqueueAutomaticProcessing(for: recording)
            touch()
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            banner = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: Deletion and retention

    func moveToTrash(_ recording: Recording) {
        pipeline.cancel(recordingID: recording.id)
        if player.loadedRecordingID == recording.id { player.unload() }
        try? store.moveToTrash(id: recording.id)
        touch()
    }

    func restore(_ recording: Recording) {
        try? store.restore(id: recording.id)
        touch()
    }

    /// Permanently deletes recordings: database rows, search index entries and the
    /// encrypted audio file, followed by a compaction so nothing lingers in free pages.
    func deletePermanently(_ recordings: [Recording]) {
        guard !recordings.isEmpty else { return }
        for recording in recordings {
            pipeline.cancel(recordingID: recording.id)
            if player.loadedRecordingID == recording.id { player.unload() }
            if let fileName = try? store.purge(id: recording.id) {
                vault.deleteAudio(fileName: fileName)
            } else {
                vault.deleteAudio(fileName: recording.fileName)
            }
        }
        try? store.compactAfterDeletion()
        touch()
    }

    func applyRetention() {
        let retention = settings.retentionDays > 0 ? settings.retentionDays : nil
        guard let due = try? store.recordingsDueForPurge(trashDays: max(1, settings.trashDays), retentionDays: retention),
              !due.isEmpty else { return }
        deletePermanently(due)
    }

    /// Removes every recording, transcript, summary, task and log entry and replaces the
    /// vault key. Installed AI models are kept; they contain no personal data.
    func eraseEverything() async {
        for job in pipeline.jobs { pipeline.cancel(recordingID: job.id) }
        if recorder.isActive { recorder.discard() }
        player.unload()
        await pipeline.engines.unloadAll()
        try? store.eraseEverything()
        try? vault.eraseAllUserData()
        touch()
    }

    // MARK: Export

    /// Writes an export to the scratch directory and returns its URL for the share sheet.
    /// Exports are plaintext by nature; the caller warns the user before sharing.
    func exportTranscript(_ recording: Recording, markdown: Bool) throws -> URL {
        let segments = try store.segments(recordingID: recording.id)
        let speakers = try store.speakers(recordingID: recording.id)
        let base = TranscriptExporter.fileName(for: recording)
        let url = vault.scratchURL(named: base + (markdown ? ".md" : ".txt"))
        let text = markdown
            ? TranscriptExporter.markdown(recording: recording, segments: segments, speakers: speakers,
                                          summary: try store.summary(recordingID: recording.id))
            : TranscriptExporter.plainText(recording: recording, segments: segments, speakers: speakers)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func exportAudio(_ recording: Recording) async throws -> URL {
        let vault = self.vault
        let url = vault.scratchURL(named: TranscriptExporter.fileName(for: recording) + "." + Vault.audioExtension(of: recording.fileName))
        try await Task.detached(priority: .userInitiated) {
            try vault.cipher.decryptFile(at: vault.audioURL(fileName: recording.fileName), to: url)
        }.value
        return url
    }
}
