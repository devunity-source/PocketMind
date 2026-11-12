import Foundation
import XCTest
@testable import PocketMindCore

final class SecurityAndPlatformTests: XCTestCase {

    // MARK: Encryption

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    func testSealOpenRoundTripAcrossChunkBoundaries() throws {
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        let chunk = 1024
        for size in [0, 1, chunk - 1, chunk, chunk + 1, chunk * 3, chunk * 3 + 17] {
            let plain = randomData(size)
            let sealed = try cipher.seal(plain, chunkSize: chunk)
            XCTAssertEqual(try cipher.open(sealed), plain, "size \(size)")
            XCTAssertGreaterThan(sealed.count, plain.count)
        }
    }

    func testFileRoundTripAndCiphertextHidesContent() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        let marker = Data("CONFIDENTIAL-BOARD-MEETING".utf8)
        var plain = Data()
        for _ in 0..<4_000 { plain.append(marker) } // ~104 KB, several chunks

        let source = directory.appendingPathComponent("audio.m4a")
        let encrypted = directory.appendingPathComponent("audio.pmenc")
        let restored = directory.appendingPathComponent("restored.m4a")
        try plain.write(to: source)

        try cipher.encryptFile(at: source, to: encrypted, chunkSize: 16_384)
        let ciphertext = try Data(contentsOf: encrypted)
        XCTAssertNil(ciphertext.range(of: marker), "plaintext must not be visible in the encrypted file")
        XCTAssertEqual(ciphertext.prefix(4), Data("PME1".utf8))

        try cipher.decryptFile(at: encrypted, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored), plain)
        XCTAssertEqual(try cipher.decryptFile(at: encrypted), plain)
        XCTAssertEqual(try cipher.open(ciphertext), plain, "file and in-memory formats are the same")
    }

    func testEmptyFileRoundTrip() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        let source = directory.appendingPathComponent("empty")
        let encrypted = directory.appendingPathComponent("empty.pmenc")
        try Data().write(to: source)
        try cipher.encryptFile(at: source, to: encrypted)
        XCTAssertEqual(try cipher.decryptFile(at: encrypted), Data())
    }

    func testWrongKeyTamperingTruncationAndReorderingAreDetected() throws {
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        let chunk = 256
        let plain = randomData(chunk * 4)
        let sealed = try cipher.seal(plain, chunkSize: chunk)
        let sealedChunk = chunk + 16

        let other = try FileCipher(keyData: FileCipher.generateKey())
        XCTAssertThrowsError(try other.open(sealed), "wrong key")

        var flipped = sealed
        flipped[flipped.count / 2] ^= 0x01
        XCTAssertThrowsError(try cipher.open(flipped), "bit flip")

        // Dropping the last chunk leaves a file that ends on a non-final chunk.
        XCTAssertThrowsError(try cipher.open(sealed.prefix(sealed.count - sealedChunk)), "truncated at a chunk boundary")
        XCTAssertThrowsError(try cipher.open(sealed.prefix(sealed.count - 5)), "truncated mid-chunk")
        XCTAssertThrowsError(try cipher.open(sealed.prefix(16)), "header only")

        // Swap chunks 0 and 1.
        var reordered = Data(sealed.prefix(16))
        reordered.append(sealed.subdata(in: (16 + sealedChunk)..<(16 + 2 * sealedChunk)))
        reordered.append(sealed.subdata(in: 16..<(16 + sealedChunk)))
        reordered.append(sealed.suffix(from: 16 + 2 * sealedChunk))
        XCTAssertThrowsError(try cipher.open(reordered), "reordered chunks")

        XCTAssertThrowsError(try cipher.open(Data("not an encrypted file at all".utf8)), "bad magic")
        XCTAssertThrowsError(try FileCipher(keyData: Data(count: 16)), "short key")
    }

    func testEncryptingTwiceGivesDifferentCiphertext() throws {
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        let plain = Data("same input".utf8)
        XCTAssertNotEqual(try cipher.seal(plain), try cipher.seal(plain), "nonces must not repeat")
    }

    func testFailedDecryptionLeavesNoPartialPlaintextFile() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cipher = try FileCipher(keyData: FileCipher.generateKey())
        var sealed = try cipher.seal(randomData(4_096), chunkSize: 1_024)
        sealed[sealed.count - 1] ^= 0xFF
        let encrypted = directory.appendingPathComponent("bad.pmenc")
        let output = directory.appendingPathComponent("out.m4a")
        try sealed.write(to: encrypted)
        XCTAssertThrowsError(try cipher.decryptFile(at: encrypted, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testChecksum() throws {
        XCTAssertEqual(Checksum.sha256Hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.bin")
        let data = randomData(300_000)
        try data.write(to: url)
        XCTAssertEqual(try Checksum.sha256Hex(of: url), Checksum.sha256Hex(of: data))
    }

    // MARK: Models

    func testCatalogEntriesArePinnedVerifiableAndOnAllowedHosts() {
        XCTAssertGreaterThanOrEqual(ModelCatalog.whisper.count, 2, "at least two transcription configurations to benchmark")
        XCTAssertGreaterThanOrEqual(ModelCatalog.languageModels.count, 2)
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count, "ids are unique")
        for model in ModelCatalog.all {
            XCTAssertEqual(model.url.scheme, "https", model.id)
            XCTAssertTrue(ModelCatalog.isAllowedHost(model.url.host), model.id)
            XCTAssertTrue(model.url.path.contains("/resolve/"), model.id)
            XCTAssertFalse(model.url.path.contains("/resolve/main/"), "\(model.id) must be pinned to a revision, not a branch")
            XCTAssertEqual(model.url.lastPathComponent, model.fileName, model.id)
            XCTAssertEqual(model.sha256.count, 64, model.id)
            XCTAssertTrue(model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, model.id)
            XCTAssertGreaterThan(model.sizeBytes, 50_000_000, model.id)
        }
        XCTAssertFalse(ModelCatalog.whisper.contains { $0.fileName.contains(".en") }, "English-only models cannot serve the other languages")
    }

    func testHostAllowList() {
        XCTAssertTrue(ModelCatalog.isAllowedHost("huggingface.co"))
        XCTAssertTrue(ModelCatalog.isAllowedHost("cdn-lfs.huggingface.co"))
        XCTAssertTrue(ModelCatalog.isAllowedHost("cas-bridge.xethub.hf.co"))
        XCTAssertFalse(ModelCatalog.isAllowedHost("huggingface.co.evil.example"))
        XCTAssertFalse(ModelCatalog.isAllowedHost("evilhuggingface.co"))
        XCTAssertFalse(ModelCatalog.isAllowedHost("example.com"))
        XCTAssertFalse(ModelCatalog.isAllowedHost(nil))
    }

    func testIncompatibleModelsAreRejected() throws {
        let large = try XCTUnwrap(ModelCatalog.descriptor(id: "phi-4-mini-instruct-q4"))
        let small = try XCTUnwrap(ModelCatalog.descriptor(id: "whisper-base"))
        let gigabyte: UInt64 = 1 << 30
        let plentyOfDisk: Int64 = 100 << 30

        XCTAssertEqual(ModelCatalog.compatibility(of: small, physicalMemory: 8 * gigabyte, freeDisk: plentyOfDisk), .compatible)
        XCTAssertFalse(ModelCatalog.compatibility(of: large, physicalMemory: 4 * gigabyte, freeDisk: plentyOfDisk).isInstallable,
                       "a 3.6 GB working set cannot run on a 4 GB phone")
        if case .warning = ModelCatalog.compatibility(of: large, physicalMemory: 8 * gigabyte, freeDisk: plentyOfDisk) {} else {
            XCTFail("the largest model should carry a memory warning on an 8 GB device")
        }
        XCTAssertFalse(ModelCatalog.compatibility(of: small, physicalMemory: 8 * gigabyte, freeDisk: 200_000_000).isInstallable,
                       "not enough free storage")
        XCTAssertTrue(ModelCatalog.compatibility(of: small, physicalMemory: 8 * gigabyte, freeDisk: 200_000_000, isInstalled: true).isInstallable,
                      "an already installed model is not blocked by low disk space")
    }

    // MARK: Audio windowing and estimates

    func testSplitPrefersSilenceNearTheEndOfAWindow() {
        let rate = 16_000
        var samples = [Float](repeating: 0, count: rate * 60)
        for index in samples.indices { samples[index] = Float(sin(Double(index) * 0.05)) * 0.5 }
        // One second of silence 8 s before the end.
        let silenceStart = rate * 51
        for index in silenceStart..<(silenceStart + rate) { samples[index] = 0 }

        let split = AudioWindowing.splitIndex(samples: samples, sampleRate: rate, searchSeconds: 20)
        XCTAssertGreaterThanOrEqual(split, silenceStart)
        XCTAssertLessThanOrEqual(split, silenceStart + rate)

        XCTAssertEqual(AudioWindowing.splitIndex(samples: [0.1, 0.2], sampleRate: rate), 2, "tiny buffers are not split")
    }

    func testProcessingEstimatesComeFromMeasurementsOnly() {
        XCTAssertNil(ProcessingEstimator.transcriptionSeconds(audioDuration: 600, realTimeFactor: nil))
        XCTAssertTrue(ProcessingEstimator.describe(seconds: nil).contains("Not measured"))
        XCTAssertEqual(ProcessingEstimator.transcriptionSeconds(audioDuration: 600, realTimeFactor: 0.1), 60)
        XCTAssertEqual(ProcessingEstimator.describe(seconds: 45), "about 45 s")
        XCTAssertEqual(ProcessingEstimator.describe(seconds: 600), "about 10 min")
    }

    // MARK: Export and recovery

    func testExportFormats() throws {
        let recording = Recording(title: "Infra: Sync/Review", createdAt: Fixtures.date(2026, 1, 27, hour: 8), duration: 95,
                                  fileName: "a.pmenc", language: "en", tags: ["infra"])
        let speaker = Speaker(id: "s1", recordingID: recording.id, label: "Speaker 1", name: "Alex")
        let segments = [
            TranscriptSegment(id: 1, recordingID: recording.id, index: 0, start: 0, end: 4, text: "Hello everyone.", speakerID: "s1"),
            TranscriptSegment(id: 2, recordingID: recording.id, index: 1, start: 65, end: 70, text: "Let's begin."),
        ]
        let utc = TimeZone(identifier: "UTC")!

        let text = TranscriptExporter.plainText(recording: recording, segments: segments, speakers: [speaker], timeZone: utc)
        XCTAssertEqual(text, "Infra: Sync/Review\n2026-01-27 08:00\n\n[00:00] Alex: Hello everyone.\n[01:05] Let's begin.\n")

        let summary = try XCTUnwrap(SummaryParser.parse(Fixtures.summaryJSON))
        let markdown = TranscriptExporter.markdown(recording: recording, segments: segments, speakers: [speaker],
                                                   summary: summary, timeZone: utc)
        XCTAssertTrue(markdown.hasPrefix("# Infra: Sync/Review\n"))
        XCTAssertTrue(markdown.contains("## Decisions\n\n- Upgrade the staging cluster next week."))
        XCTAssertTrue(markdown.contains("- [ ] Review the cluster monitoring dashboards — Alex"))
        XCTAssertTrue(markdown.contains("**01:05** Let's begin."))
        XCTAssertTrue(markdown.contains("- **Language:** English"))

        XCTAssertEqual(TranscriptExporter.fileName(for: recording), "Infra_ Sync_Review")
    }

    func testInterruptedRecordingIsFoundAgain() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = RecoveryJournal(recordingID: "abc", title: "Standup", startedAt: Fixtures.date(2026, 1, 27),
                                      audioFileName: "abc.m4a", quality: .high, kind: .meeting, tags: ["team"])
        try journal.write(to: directory)
        try Data("unrelated".utf8).write(to: directory.appendingPathComponent("abc.m4a"))

        XCTAssertEqual(RecoveryJournal.pending(in: directory), [journal])
        RecoveryJournal.remove(recordingID: "abc", from: directory)
        XCTAssertTrue(RecoveryJournal.pending(in: directory).isEmpty)
    }

    // MARK: Offline guarantee

    /// Static audit of the whole repository: networking APIs and URLs may appear only in
    /// the model downloader and the model catalog. Recording, transcription,
    /// summarisation and search therefore have no code path that can reach the network.
    func testOnlyTheModelDownloaderCanTouchTheNetwork() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoots = ["App", "Packages/PocketMindCore/Sources", "Packages/LocalAI/Sources"]
        let forbidden = ["URLSession", "URLRequest", "NWConnection", "NWPathMonitor", "import Network", "CFNetwork",
                         "WKWebView", "SFSafariViewController", "CloudKit", "NSUbiquitous", "http://", "https://",
                         "MultipeerConnectivity", "StoreKit", "AdSupport", "AppTrackingTransparency"]
        let allowed: [String: Set<String>] = [
            "ModelManager.swift": ["URLSession", "URLRequest", "https://"],
            "ModelCatalog.swift": ["https://"],
        ]

        var scanned = 0
        var violations: [String] = []
        for sourceRoot in sourceRoots {
            let directory = root.appendingPathComponent(sourceRoot)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where ["swift", "plist", "yml"].contains(url.pathExtension) {
                // Info.plist legitimately carries Apple's DTD URL in its DOCTYPE line.
                let text = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: "http://www.apple.com/DTDs/PropertyList-1.0.dtd", with: "")
                scanned += 1
                for token in forbidden where text.contains(token) {
                    if allowed[url.lastPathComponent]?.contains(token) == true { continue }
                    violations.append("\(url.lastPathComponent): \(token)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "the audit must actually find the sources (looked under \(root.path))")
        XCTAssertEqual(violations, [], "network-capable API outside the model downloader")
    }

    /// The same pipeline the app runs — store transcript, summarise, extract tasks, answer
    /// a question — executed with engines that perform no I/O. If any step needed a
    /// network service, it could not complete here.
    func testWholePipelineRunsWithoutAnyNetworkDependency() async throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Infrastructure Sync", date: Fixtures.date(2026, 1, 27),
                                                  lines: Fixtures.infrastructureLines)
        let model = FakeLanguageModel { messages in
            messages[0].content.contains("structured notes") ? Fixtures.summaryJSON : "Upgrade staging next week [S1]."
        }
        let segments = try store.segments(recordingID: recording.id)
        let summary = try await Summarizer(llm: model).summarize(segments: segments, title: recording.title, template: .meeting)
        try store.save(summary, recordingID: recording.id)
        try store.replaceExtractedTasks(recordingID: recording.id, with:
            TaskExtractor.tasks(from: summary, recording: recording, segments: segments, calendar: Fixtures.utc))
        try store.setStatus(.ready, for: recording.id)

        let answer = try await MemoryService(store: store, llm: model, calendar: Fixtures.utc)
            .answer(question: "What did we decide about the staging cluster?", now: Fixtures.date(2026, 1, 28))

        XCTAssertEqual(try store.recording(id: recording.id)?.status, .ready)
        XCTAssertEqual(try store.tasks(.open).count, 2)
        XCTAssertEqual(answer.sources.first?.recordingID, recording.id)
        XCTAssertTrue(try store.networkEvents().isEmpty, "nothing in the pipeline logged or made a network request")
    }
}
