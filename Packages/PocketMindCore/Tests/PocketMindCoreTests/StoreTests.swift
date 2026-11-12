import Foundation
import XCTest
@testable import PocketMindCore

final class StoreTests: XCTestCase {

    // MARK: Recording library

    func testRecordingRoundTripKeepsEveryField() throws {
        let store = try Fixtures.memoryStore()
        let folder = Folder(name: "Work")
        try store.save(folder)
        let recording = Recording(
            title: "Infrastructure Sync", createdAt: Fixtures.date(2026, 1, 27), duration: 2700,
            fileName: "a.pmenc", fileSize: 36_000_000, quality: .high, language: "en", kind: .meeting,
            folderID: folder.id, isFavorite: true, tags: ["infra", "k8s"], status: .ready, modelUsed: "whisper-small-q5")
        try store.save(recording)
        XCTAssertEqual(try store.recording(id: recording.id), recording)
    }

    func testFiltersByKindFavoriteTagFolderLanguageAndDate() throws {
        let store = try Fixtures.memoryStore()
        let folder = Folder(name: "Clients")
        try store.save(folder)
        var a = try Fixtures.addRecording(to: store, title: "Standup", date: Fixtures.date(2026, 1, 19), lines: ["Quick update."], tags: ["team"])
        let b = try Fixtures.addRecording(to: store, title: "Client call", date: Fixtures.date(2026, 1, 20), lines: ["Bonjour."],
                                          kind: .call, language: "fr", tags: ["client", "team-lead"])
        a.isFavorite = true
        a.folderID = folder.id
        try store.save(a)

        var filter = LibraryFilter()
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [b.id, a.id], "newest first")

        filter.kind = .call
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [b.id])

        filter = LibraryFilter(); filter.favoritesOnly = true
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [a.id])

        filter = LibraryFilter(); filter.tag = "team"
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [a.id], "tag match is exact, not a prefix")

        filter = LibraryFilter(); filter.folderID = folder.id
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [a.id])

        filter = LibraryFilter(); filter.language = "fr"
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [b.id])

        filter = LibraryFilter()
        filter.dateRange = DateInterval(start: Fixtures.date(2026, 1, 20, hour: 0), end: Fixtures.date(2026, 1, 21, hour: 0))
        XCTAssertEqual(try store.recordings(matching: filter).map(\.id), [b.id])

        XCTAssertEqual(try store.allTags(), ["client", "team", "team-lead"])
        XCTAssertEqual(try store.allLanguages(), ["en", "fr"])
    }

    func testDeletingFolderKeepsItsRecordings() throws {
        let store = try Fixtures.memoryStore()
        let folder = Folder(name: "Temp")
        try store.save(folder)
        var recording = try Fixtures.addRecording(to: store, title: "A", date: Date(), lines: ["Hello there."])
        recording.folderID = folder.id
        try store.save(recording)
        try store.deleteFolder(id: folder.id)
        XCTAssertNil(try store.recording(id: recording.id)?.folderID)
        XCTAssertTrue(try store.folders().isEmpty)
    }

    // MARK: Transcript persistence

    func testTranscriptPersistsWithTimestampsAndSurvivesReopen() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pm.sqlite").path

        var recordingID = ""
        do {
            let store = try Store(path: path)
            let recording = try Fixtures.addRecording(to: store, title: "Infra", date: Date(), lines: Fixtures.infrastructureLines)
            recordingID = recording.id
            store.db.close()
        }

        let reopened = try Store(path: path)
        let segments = try reopened.segments(recordingID: recordingID)
        XCTAssertEqual(segments.count, Fixtures.infrastructureLines.count)
        XCTAssertEqual(segments[3].text, "We decided to upgrade the staging cluster next week.")
        XCTAssertEqual(segments[3].start, 15)
        XCTAssertEqual(segments[3].end, 20)
        XCTAssertEqual(try reopened.recording(id: recordingID)?.language, "en")
    }

    func testManualCorrectionUpdatesSearchIndex() throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Infra", date: Date(),
                                                  lines: ["We talked about terror form modules.", "Nothing else."])
        XCTAssertTrue(try store.searchChunks(ftsQuery: "\"terraform\"*").isEmpty)

        let segment = try XCTUnwrap(store.segments(recordingID: recording.id).first)
        try store.updateSegmentText(id: segment.id, text: "We talked about Terraform modules.")

        let updated = try XCTUnwrap(store.segments(recordingID: recording.id).first)
        XCTAssertTrue(updated.isEdited)
        XCTAssertEqual(try store.searchChunks(ftsQuery: "\"terraform\"*").count, 1)
        XCTAssertTrue(try store.searchChunks(ftsQuery: "\"terror\"*").isEmpty, "old wording must leave the index")
    }

    func testSpeakersCanBeAddedRenamedAssignedAndRemoved() throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Call", date: Date(), lines: ["Hi.", "Hello."])
        var first = try store.addSpeaker(recordingID: recording.id)
        let second = try store.addSpeaker(recordingID: recording.id)
        XCTAssertEqual([first.label, second.label], ["Speaker 1", "Speaker 2"])

        first.name = "Alex"
        try store.save(first)
        let segments = try store.segments(recordingID: recording.id)
        try store.assignSpeaker(first.id, toSegment: segments[0].id)
        try store.assignSpeaker(second.id, toSegment: segments[1].id)

        XCTAssertEqual(try store.speakers(recordingID: recording.id).map(\.displayName), ["Alex", "Speaker 2"])
        XCTAssertEqual(try store.segments(recordingID: recording.id).map(\.speakerID), [first.id, second.id])

        try store.deleteSpeaker(id: second.id)
        XCTAssertEqual(try store.segments(recordingID: recording.id).map(\.speakerID), [first.id, nil])
    }

    // MARK: Search accuracy

    func testSearchFindsTheRightRecordingAndTimestamp() throws {
        let store = try Fixtures.memoryStore()
        let infra = try Fixtures.addRecording(to: store, title: "Infrastructure Sync", date: Fixtures.date(2026, 1, 27),
                                              lines: Fixtures.infrastructureLines)
        try Fixtures.addRecording(to: store, title: "Product Planning", date: Fixtures.date(2026, 1, 26),
                                  lines: ["We reviewed the roadmap for the mobile app.", "Pricing stays the same this quarter."])

        let fts = try XCTUnwrap(SearchQuery.ftsExpression(for: ["terraform"]))
        let hits = try store.searchChunks(ftsQuery: fts)
        XCTAssertEqual(hits.map(\.chunk.recordingID), [infra.id])
        XCTAssertEqual(hits.first?.recordingTitle, "Infrastructure Sync")
        XCTAssertTrue(hits.first?.chunk.text.contains("Terraform") ?? false)

        var filter = LibraryFilter()
        filter.searchText = "roadmap"
        XCTAssertEqual(try store.recordings(matching: filter).map(\.title), ["Product Planning"])
        filter.searchText = "planning"
        XCTAssertEqual(try store.recordings(matching: filter).map(\.title), ["Product Planning"], "titles are searched too")
        filter.searchText = "zebra"
        XCTAssertTrue(try store.recordings(matching: filter).isEmpty)
    }

    func testSearchHandlesInflectionsAndQuerySyntaxSafely() throws {
        let store = try Fixtures.memoryStore()
        try Fixtures.addRecording(to: store, title: "Infra", date: Date(), lines: Fixtures.infrastructureLines)

        // "deploying" should find "deployment"; "clusters" should find "cluster".
        for word in ["deploying", "clusters", "upgraded"] {
            let fts = try XCTUnwrap(SearchQuery.ftsExpression(for: SearchQuery.keywords(in: word)))
            XCTAssertFalse(try store.searchChunks(ftsQuery: fts).isEmpty, word)
        }

        // Input containing FTS operators and quotes must not raise a syntax error.
        var filter = LibraryFilter()
        for hostile in ["\"unbalanced", "NEAR(a b) OR *", "cluster AND NOT (", "a:b^c - d", "'; DROP TABLE recordings; --"] {
            filter.searchText = hostile
            XCTAssertNoThrow(try store.recordings(matching: filter), hostile)
        }
        XCTAssertEqual(try store.recordings().count, 1)
    }

    func testSearchWorksForArabicUkrainianDutchAndFrench() throws {
        let store = try Fixtures.memoryStore()
        let arabic = try Fixtures.addRecording(to: store, title: "اجتماع", date: Date(),
                                               lines: ["ناقشنا ترقية الخوادم الأسبوع القادم."], language: "ar")
        let ukrainian = try Fixtures.addRecording(to: store, title: "Зустріч", date: Date(),
                                                  lines: ["Ми вирішили оновити кластер наступного тижня."], language: "uk")
        let dutch = try Fixtures.addRecording(to: store, title: "Overleg", date: Date(),
                                              lines: ["We hebben besloten de begroting te verhogen."], language: "nl")
        let french = try Fixtures.addRecording(to: store, title: "Réunion", date: Date(),
                                               lines: ["Nous avons décidé de reporter la livraison."], language: "fr")

        func ids(_ word: String) throws -> [String] {
            let fts = try XCTUnwrap(SearchQuery.ftsExpression(for: SearchQuery.keywords(in: word)))
            return try store.searchChunks(ftsQuery: fts).map(\.chunk.recordingID)
        }
        XCTAssertEqual(try ids("الخوادم"), [arabic.id])
        XCTAssertEqual(try ids("кластер"), [ukrainian.id])
        XCTAssertEqual(try ids("begroting"), [dutch.id])
        XCTAssertEqual(try ids("livraison"), [french.id])
        let unaccented = try XCTUnwrap(SearchQuery.ftsExpression(for: ["decide"]))
        XCTAssertEqual(try store.searchChunks(ftsQuery: unaccented).map(\.chunk.recordingID), [french.id],
                       "diacritics are folded: decide matches décidé")
    }

    func testSearchRespectsDateRange() throws {
        let store = try Fixtures.memoryStore()
        try Fixtures.addRecording(to: store, title: "Old", date: Fixtures.date(2025, 6, 1), lines: ["Terraform state migration."])
        let recent = try Fixtures.addRecording(to: store, title: "New", date: Fixtures.date(2026, 1, 27), lines: ["Terraform module cleanup."])
        let january = DateInterval(start: Fixtures.date(2026, 1, 1, hour: 0), end: Fixtures.date(2026, 2, 1, hour: 0))
        XCTAssertEqual(try store.searchChunks(ftsQuery: "\"terraform\"*", in: january).map(\.chunk.recordingID), [recent.id])
        XCTAssertEqual(try store.searchChunks(ftsQuery: "\"terraform\"*").count, 2)
    }

    // MARK: Deletion

    func testTrashHidesRecordingFromLibrarySearchAndTasksUntilRestored() throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Infra", date: Date(), lines: Fixtures.infrastructureLines)
        try store.save(TaskItem(recordingID: recording.id, title: "Prepare Terraform changes", origin: .extracted))

        try store.moveToTrash(id: recording.id)
        XCTAssertTrue(try store.recordings().isEmpty)
        XCTAssertTrue(try store.searchChunks(ftsQuery: "\"terraform\"*").isEmpty)
        XCTAssertTrue(try store.tasks().isEmpty)
        var trash = LibraryFilter(); trash.trashed = true
        XCTAssertEqual(try store.recordings(matching: trash).map(\.id), [recording.id])

        try store.restore(id: recording.id)
        XCTAssertEqual(try store.recordings().count, 1)
        XCTAssertEqual(try store.searchChunks(ftsQuery: "\"terraform\"*").count, 1)
        XCTAssertEqual(try store.tasks().count, 1)
    }

    func testPurgeRemovesEveryTraceAndReturnsAudioFileName() throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Infra", date: Date(), lines: Fixtures.infrastructureLines)
        let keep = try Fixtures.addRecording(to: store, title: "Other", date: Date(), lines: ["Terraform is also mentioned here."])
        try store.save(MeetingSummary(title: "Infra", overview: "x"), recordingID: recording.id)
        try store.save(TaskItem(recordingID: recording.id, title: "Prepare Terraform changes", origin: .extracted))
        _ = try store.addSpeaker(recordingID: recording.id)

        XCTAssertEqual(try store.purge(id: recording.id), recording.fileName)

        XCTAssertNil(try store.recording(id: recording.id))
        XCTAssertTrue(try store.segments(recordingID: recording.id).isEmpty)
        XCTAssertNil(try store.summary(recordingID: recording.id))
        XCTAssertTrue(try store.speakers(recordingID: recording.id).isEmpty)
        XCTAssertEqual(try store.db.scalarInt("SELECT COUNT(*) FROM tasks"), 0)
        XCTAssertEqual(try store.db.scalarInt("SELECT COUNT(*) FROM chunks WHERE recording_id = ?", [.text(recording.id)]), 0)
        XCTAssertEqual(try store.searchChunks(ftsQuery: "\"terraform\"*").map(\.chunk.recordingID), [keep.id])
        XCTAssertNoThrow(try store.db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('integrity-check')"))
    }

    func testPurgedTextIsNotLeftInTheDatabaseFiles() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("pm.sqlite").path
        let store = try Store(path: path)
        let marker = "xylophonequartzmarker"
        let recording = try Fixtures.addRecording(
            to: store, title: "Secret \(marker)", date: Date(),
            lines: (0..<200).map { "Line \($0) mentions \(marker) in a confidential way." })

        func filesContainMarker() throws -> Bool {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if try Data(contentsOf: url).range(of: Data(marker.utf8)) != nil { return true }
            }
            return false
        }
        _ = try store.db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertTrue(try filesContainMarker(), "sanity check: the text is on disk before deletion")

        try store.purge(id: recording.id)
        try store.compactAfterDeletion()
        XCTAssertFalse(try filesContainMarker(), "deleted transcript text must not remain in the database or WAL")
    }

    func testRetentionSelectsExpiredTrashAndOldNonFavourites() throws {
        let store = try Fixtures.memoryStore()
        let now = Fixtures.date(2026, 3, 1)
        let oldTrash = try Fixtures.addRecording(to: store, title: "Old trash", date: Fixtures.date(2026, 1, 1), lines: ["a b c."])
        let freshTrash = try Fixtures.addRecording(to: store, title: "Fresh trash", date: Fixtures.date(2026, 2, 20), lines: ["a b c."])
        let ancient = try Fixtures.addRecording(to: store, title: "Ancient", date: Fixtures.date(2025, 1, 1), lines: ["a b c."])
        var ancientFavourite = try Fixtures.addRecording(to: store, title: "Ancient fav", date: Fixtures.date(2025, 1, 1), lines: ["a b c."])
        ancientFavourite.isFavorite = true
        try store.save(ancientFavourite)
        try store.moveToTrash(id: oldTrash.id, at: Fixtures.date(2026, 1, 10))
        try store.moveToTrash(id: freshTrash.id, at: Fixtures.date(2026, 2, 25))

        XCTAssertEqual(try store.recordingsDueForPurge(now: now, trashDays: 30, retentionDays: nil).map(\.id), [oldTrash.id])
        XCTAssertEqual(Set(try store.recordingsDueForPurge(now: now, trashDays: 30, retentionDays: 365).map(\.id)),
                       [oldTrash.id, ancient.id])
    }

    func testEraseEverythingLeavesAnEmptyDatabase() throws {
        let store = try Fixtures.memoryStore()
        try Fixtures.addRecording(to: store, title: "Infra", date: Date(), lines: Fixtures.infrastructureLines)
        try store.logNetwork(host: "huggingface.co", purpose: "Model download", bytes: 10)
        try store.eraseEverything()
        let stats = try store.stats()
        XCTAssertEqual(stats.recordings + stats.trashed + stats.segments + stats.summaries + stats.tasks, 0)
        XCTAssertTrue(try store.networkEvents().isEmpty)
        XCTAssertTrue(try store.searchChunks(ftsQuery: "\"terraform\"*").isEmpty)
    }

    // MARK: Summaries, tasks, templates, logs

    func testSummaryAndTaskPersistence() throws {
        let store = try Fixtures.memoryStore()
        let recording = try Fixtures.addRecording(to: store, title: "Infra", date: Fixtures.date(2026, 1, 27), lines: Fixtures.infrastructureLines)
        let summary = try XCTUnwrap(SummaryParser.parse(Fixtures.summaryJSON))
        try store.save(summary, recordingID: recording.id)
        XCTAssertEqual(try store.summary(recordingID: recording.id)?.decisions, summary.decisions)

        let segments = try store.segments(recordingID: recording.id)
        let tasks = TaskExtractor.tasks(from: summary, recording: recording, segments: segments, calendar: Fixtures.utc)
        try store.replaceExtractedTasks(recordingID: recording.id, with: tasks)
        XCTAssertEqual(try store.tasks(.open).count, 2)

        // Completing a task and re-running extraction must not resurrect or duplicate it.
        let done = try XCTUnwrap(store.tasks(.open).first { $0.title.contains("Terraform") })
        try store.setTaskDone(true, id: done.id)
        try store.save(TaskItem(recordingID: recording.id, title: "Manual follow-up", origin: .manual))
        try store.replaceExtractedTasks(recordingID: recording.id, with: tasks)

        XCTAssertEqual(try store.tasks(.completed).map(\.title), ["Prepare the Terraform changes"])
        XCTAssertEqual(Set(try store.tasks(.open).map(\.title)), ["Review the cluster monitoring dashboards", "Manual follow-up"])
    }

    func testCustomTemplatesAndNetworkLogAndBenchmarks() throws {
        let store = try Fixtures.memoryStore()
        let template = SummaryTemplate(name: "1:1", instructions: "Focus on feedback.")
        try store.save(template)
        XCTAssertEqual(try store.allTemplates().count, SummaryTemplate.builtIns.count + 1)
        XCTAssertEqual(try store.template(id: template.id).name, "1:1")
        XCTAssertEqual(try store.template(id: "missing").id, SummaryTemplate.meeting.id)
        try store.deleteTemplate(id: template.id)
        XCTAssertTrue(try store.customTemplates().isEmpty)

        XCTAssertTrue(try store.networkEvents().isEmpty, "a fresh install has made no network requests")
        try store.logNetwork(host: "huggingface.co", purpose: "Model download: whisper-base", bytes: 147_951_465)
        XCTAssertEqual(try store.networkEvents().first?.host, "huggingface.co")

        try store.save(BenchmarkResult(modelID: "whisper-base", rate: 0.08, detail: "30 s sample"))
        XCTAssertEqual(try store.benchmark(modelID: "whisper-base")?.rate, 0.08)
        XCTAssertNil(try store.benchmark(modelID: "other"))
    }

    // MARK: Large recordings

    func testThreeHourTranscriptIsStoredChunkedAndSearchable() throws {
        let store = try Fixtures.memoryStore()
        // ~3 hours of speech in 4-second segments.
        var lines = (0..<2700).map { "Segment \($0) continues the general discussion about quarterly planning topics." }
        lines[2500] = "Right at the end somebody mentioned the hippopotamus migration project."
        let started = Date()
        let recording = try Fixtures.addRecording(to: store, title: "All hands", date: Date(), lines: lines)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "indexing a 3-hour transcript should take seconds")

        XCTAssertEqual(try store.segments(recordingID: recording.id).count, 2700)
        let chunks = try store.chunks(recordingID: recording.id)
        XCTAssertGreaterThan(chunks.count, 100)
        XCTAssertLessThanOrEqual(chunks.map(\.text.count).max() ?? 0, 1_000)

        let hit = try XCTUnwrap(store.searchChunks(ftsQuery: "\"hippopotamus\"*").first)
        XCTAssertEqual(hit.chunk.recordingID, recording.id)
        XCTAssertLessThanOrEqual(hit.chunk.start, 2500 * 5)
        XCTAssertGreaterThanOrEqual(hit.chunk.end, 2500 * 5)
    }
}
