import AVFoundation
import XCTest
import PocketMindCore
@testable import PocketMind

// App-level tests. They need the iOS SDK and run on the simulator (scripts/test.sh or CI).
// Tests that need a working microphone skip themselves where the simulator has none.

@MainActor
final class VaultTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        vault = try Vault(root: root, keyData: FileCipher.generateKey())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recording(fileName: String) -> Recording {
        Recording(title: "Test", fileName: fileName)
    }

    func testSealingEncryptsRemovesPlaintextAndRoundTrips() async throws {
        let marker = Data("PLAINTEXT-AUDIO-MARKER".utf8)
        let plain = vault.captureDirectory.appendingPathComponent("abc.m4a")
        try marker.write(to: plain)

        let sealed = try vault.sealAudio(at: plain, recordingID: "abc")

        XCTAssertEqual(sealed.fileName, "abc.m4a.pmenc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path), "the plaintext capture must be removed")
        let stored = try Data(contentsOf: vault.audioURL(fileName: sealed.fileName))
        XCTAssertNil(stored.range(of: marker))
        XCTAssertEqual(try vault.audioData(for: recording(fileName: sealed.fileName)), marker)
    }

    func testDecryptedScratchFileIsDeletedAfterUseEvenOnError() async throws {
        let plain = vault.captureDirectory.appendingPathComponent("x.wav")
        try Data(repeating: 7, count: 2_000).write(to: plain)
        let sealed = try vault.sealAudio(at: plain, recordingID: "x")
        let item = recording(fileName: sealed.fileName)

        var seen: URL?
        try await vault.withDecryptedAudio(for: item) { url in
            seen = url
            XCTAssertEqual(url.pathExtension, "wav", "the original container type is preserved for decoding")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(seen).path))

        struct Boom: Error {}
        do {
            try await vault.withDecryptedAudio(for: item) { url in
                seen = url
                throw Boom()
            }
            XCTFail("expected an error")
        } catch is Boom {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(seen).path))
    }

    func testMissingAudioIsReported() {
        XCTAssertThrowsError(try vault.audioData(for: recording(fileName: "nope.m4a.pmenc")))
    }

    func testVaultIsExcludedFromBackupAndScratchIsWipedAtLaunch() throws {
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let leftover = vault.scratchURL(named: "export.txt")
        try Data("secret".utf8).write(to: leftover)
        _ = try Vault(root: root, keyData: FileCipher.generateKey())
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testAudioExtensionParsing() {
        XCTAssertEqual(Vault.audioExtension(of: "id.mp3.pmenc"), "mp3")
        XCTAssertEqual(Vault.audioExtension(of: "id.pmenc"), "m4a")
    }

    func testKeychainKeyIsStableAcrossLoads() throws {
        KeychainKeyStore.delete()
        defer { KeychainKeyStore.delete() }
        let first: Data
        do {
            first = try KeychainKeyStore.loadOrCreate()
        } catch {
            throw XCTSkip("Keychain is not available in this test host: \(error)")
        }
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(try KeychainKeyStore.loadOrCreate(), first)
        KeychainKeyStore.delete()
        XCTAssertNotEqual(try KeychainKeyStore.loadOrCreate(), first, "erasing the key makes old ciphertext unreadable")
    }
}

final class AudioDecodingTests: XCTestCase {
    /// Writes a stereo 44.1 kHz sine wave so the reader has to resample and downmix.
    private func makeAudioFile(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
            for frame in 0..<Int(frames) { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44_100)) * 0.5 }
        }
        try file.write(from: buffer)
        return url
    }

    func testReaderProduces16kMonoInBoundedWindows() throws {
        let url = try makeAudioFile(seconds: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try AudioWindowReader(url: url)
        XCTAssertEqual(reader.duration, 5, accuracy: 0.05)

        let first = try reader.read(seconds: 2)
        XCTAssertEqual(Double(first.count), 32_000, accuracy: 400)
        XCTAssertFalse(reader.isAtEnd)
        XCTAssertGreaterThan(first.map(abs).max() ?? 0, 0.2, "the tone must survive conversion")

        var total = first.count
        while !reader.isAtEnd {
            total += try reader.read(seconds: 2).count
        }
        XCTAssertEqual(Double(total), 80_000, accuracy: 1_600)
    }

    func testSeekResumesFromAPosition() throws {
        let url = try makeAudioFile(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try AudioWindowReader(url: url)
        reader.seek(toSeconds: 3)
        var count = 0
        while !reader.isAtEnd { count += try reader.read(seconds: 10).count }
        XCTAssertEqual(Double(count), 16_000, accuracy: 1_600)
        XCTAssertEqual(AudioWindowReader.duration(of: URL(fileURLWithPath: "/nonexistent.m4a")), 0)
    }
}

@MainActor
final class RecorderLifecycleTests: XCTestCase {
    private var directory: URL!
    private var recorder: AudioRecorderService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        recorder = AudioRecorderService(captureDirectory: directory)
    }

    override func tearDown() async throws {
        if recorder.isActive { recorder.discard() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func startOrSkip() async throws {
        guard AudioRecorderService.permissionGranted else {
            throw XCTSkip("Microphone permission has not been granted to the test host (CI grants it with simctl).")
        }
        do {
            try await recorder.start(title: "Test", kind: .note, quality: .compact, freeDiskSpace: 10_000_000_000)
        } catch {
            throw XCTSkip("This simulator cannot record audio: \(error.localizedDescription)")
        }
    }

    func testLowStorageAndPermissionAreCheckedBeforeRecording() async {
        do {
            try await recorder.start(title: "Test", kind: .note, quality: .compact, freeDiskSpace: 1_000)
            XCTFail("recording must not start without storage")
        } catch let error as RecorderError {
            // Without permission the permission error comes first; with it, storage.
            XCTAssertTrue(error == .lowStorage || error == .microphoneDenied)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue(RecoveryJournal.pending(in: directory).isEmpty, "a refused start leaves nothing behind")
    }

    func testStartPauseResumeStopLeavesAudioAndJournal() async throws {
        try await startOrSkip()
        XCTAssertEqual(recorder.state, .recording)
        XCTAssertEqual(RecoveryJournal.pending(in: directory).count, 1, "the journal exists from the first moment")

        recorder.pause()
        XCTAssertEqual(recorder.state, .paused)
        recorder.resume()
        XCTAssertEqual(recorder.state, .recording)

        try await Task.sleep(for: .milliseconds(700))
        recorder.title = "Renamed while recording"
        recorder.tags = ["a", "b"]
        recorder.stop()
        XCTAssertEqual(recorder.state, .idle)

        let journal = try XCTUnwrap(RecoveryJournal.pending(in: directory).first)
        XCTAssertEqual(journal.title, "Renamed while recording")
        XCTAssertEqual(journal.tags, ["a", "b"])
        let audio = directory.appendingPathComponent(journal.audioFileName)
        XCTAssertGreaterThan(AudioWindowReader.duration(of: audio), 0.3, "the stopped file is a readable recording")
    }

    func testDiscardRemovesAudioAndJournal() async throws {
        try await startOrSkip()
        recorder.discard()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    func testInterruptionPausesAndResumes() async throws {
        try await startOrSkip()
        let session = AVAudioSession.sharedInstance()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.state, .paused)
        XCTAssertNotNil(recorder.notice, "the user is told why recording paused")

        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: session, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
        ])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(recorder.state, .recording)
        recorder.discard()
    }
}

@MainActor
final class ModelManagerTests: XCTestCase {
    func testInstalledStateSelectionAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let store = try Store(path: ":memory:")
        let manager = ModelManager(directory: directory, store: store, settings: settings, freeDiskSpace: { 50_000_000_000 })

        let model = try XCTUnwrap(ModelCatalog.whisper.first)
        XCTAssertEqual(manager.state(of: model), .notInstalled)
        XCTAssertNil(manager.activeWhisperModel)

        try Data("stand-in".utf8).write(to: manager.fileURL(for: model))
        manager.refresh()
        XCTAssertEqual(manager.state(of: model), .installed)
        XCTAssertEqual(manager.activeWhisperModel?.id, model.id, "the first installed model is selected automatically")

        manager.delete(model)
        XCTAssertEqual(manager.state(of: model), .notInstalled)
        XCTAssertNil(manager.activeWhisperModel)
        XCTAssertTrue(try store.networkEvents().isEmpty, "none of this touched the network")
    }

    func testDefaultsFavourPrivacy() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tests-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.appLockEnabled)
        XCTAssertTrue(settings.wifiOnlyDownloads)
        XCTAssertEqual(settings.trashDays, 30)
        XCTAssertEqual(settings.retentionDays, 0)
    }
}
