import Foundation

public struct LibraryFilter: Sendable, Equatable {
    public var searchText: String = ""
    public var kind: RecordingKind?
    public var language: String?
    public var folderID: String?
    public var tag: String?
    public var favoritesOnly = false
    public var dateRange: DateInterval?
    public var trashed = false

    public init() {}
}

public struct ChunkHit: Hashable, Sendable {
    public var chunk: TranscriptChunk
    public var recordingTitle: String
    public var recordingDate: Date
    /// bm25 score; lower is a better match.
    public var rank: Double
    public var snippet: String
}

/// Repository over the SQLite database. Synchronous by design: every call is short, and
/// callers that need to stay off the main thread wrap calls in a task.
public final class Store: @unchecked Sendable {
    public let db: Database

    public init(database: Database) throws {
        self.db = database
        try migrate()
    }

    public convenience init(path: String) throws {
        try self.init(database: Database(path: path))
    }

    // MARK: - Schema

    static let schemaVersion: Int64 = 1

    private func migrate() throws {
        // FTS5's 'secure-delete' option is deliberately not used: several SQLite releases
        // corrupt external-content indexes with it. compactAfterDeletion() removes deleted
        // words from the index instead, on every SQLite version.
        let version = try db.scalarInt("PRAGMA user_version")
        guard version < Store.schemaVersion else { return }
        try db.transaction {
            try db.executeScript("""
            CREATE TABLE IF NOT EXISTS folders (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL);

            CREATE TABLE IF NOT EXISTS recordings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                duration REAL NOT NULL DEFAULT 0,
                file_name TEXT NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                quality TEXT NOT NULL,
                language TEXT,
                kind TEXT NOT NULL,
                folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                tags TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL,
                error TEXT,
                deleted_at REAL,
                model_used TEXT);
            CREATE INDEX IF NOT EXISTS recordings_created ON recordings(created_at DESC);

            CREATE TABLE IF NOT EXISTS speakers (
                id TEXT PRIMARY KEY,
                recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                label TEXT NOT NULL,
                name TEXT);

            CREATE TABLE IF NOT EXISTS segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                idx INTEGER NOT NULL,
                start_s REAL NOT NULL,
                end_s REAL NOT NULL,
                text TEXT NOT NULL,
                speaker_id TEXT,
                edited INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS segments_recording ON segments(recording_id, idx);

            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
                start_s REAL NOT NULL,
                end_s REAL NOT NULL,
                text TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS chunks_recording ON chunks(recording_id);

            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                text, content='chunks', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2');
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
            END;

            CREATE TABLE IF NOT EXISTS summaries (
                recording_id TEXT PRIMARY KEY REFERENCES recordings(id) ON DELETE CASCADE,
                json TEXT NOT NULL,
                created_at REAL NOT NULL);

            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                recording_id TEXT REFERENCES recordings(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                owner TEXT,
                due_at REAL,
                due_text TEXT,
                is_done INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                source_start REAL,
                origin TEXT NOT NULL);

            CREATE TABLE IF NOT EXISTS templates (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, instructions TEXT NOT NULL);

            CREATE TABLE IF NOT EXISTS network_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL, host TEXT NOT NULL, purpose TEXT NOT NULL, bytes INTEGER NOT NULL);

            CREATE TABLE IF NOT EXISTS benchmarks (
                model_id TEXT PRIMARY KEY, rate REAL NOT NULL, measured_at REAL NOT NULL, detail TEXT NOT NULL);
            """)
            try db.execute("PRAGMA user_version = \(Store.schemaVersion)")
        }
    }

    // MARK: - Recordings

    private static let jsonEncoder = JSONEncoder()
    private static let jsonDecoder = JSONDecoder()

    private static func encodeTags(_ tags: [String]) -> String {
        (try? String(decoding: jsonEncoder.encode(tags), as: UTF8.self)) ?? "[]"
    }

    private static func decodeTags(_ text: String?) -> [String] {
        guard let data = text?.data(using: .utf8) else { return [] }
        return (try? jsonDecoder.decode([String].self, from: data)) ?? []
    }

    private static func recording(from row: DBRow) -> Recording? {
        guard let id = row.string("id"), let title = row.string("title"),
              let createdAt = row.date("created_at"), let fileName = row.string("file_name") else { return nil }
        return Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: row.double("duration") ?? 0,
            fileName: fileName,
            fileSize: row.int("file_size") ?? 0,
            quality: RecordingQuality(rawValue: row.string("quality") ?? "") ?? .standard,
            language: row.string("language"),
            kind: RecordingKind(rawValue: row.string("kind") ?? "") ?? .meeting,
            folderID: row.string("folder_id"),
            isFavorite: row.bool("is_favorite"),
            tags: decodeTags(row.string("tags")),
            status: ProcessingStatus(rawValue: row.string("status") ?? "") ?? .recorded,
            errorMessage: row.string("error"),
            deletedAt: row.date("deleted_at"),
            modelUsed: row.string("model_used"))
    }

    /// Inserts or fully replaces a recording row.
    public func save(_ r: Recording) throws {
        try db.execute("""
            INSERT INTO recordings (id, title, created_at, duration, file_name, file_size, quality, language,
                kind, folder_id, is_favorite, tags, status, error, deleted_at, model_used)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, created_at=excluded.created_at, duration=excluded.duration,
                file_name=excluded.file_name, file_size=excluded.file_size, quality=excluded.quality,
                language=excluded.language, kind=excluded.kind, folder_id=excluded.folder_id,
                is_favorite=excluded.is_favorite, tags=excluded.tags, status=excluded.status,
                error=excluded.error, deleted_at=excluded.deleted_at, model_used=excluded.model_used
            """, [
                .text(r.id), .text(r.title), .date(r.createdAt), .double(r.duration), .text(r.fileName),
                .int(r.fileSize), .text(r.quality.rawValue), .optional(r.language), .text(r.kind.rawValue),
                .optional(r.folderID), .bool(r.isFavorite), .text(Store.encodeTags(r.tags)),
                .text(r.status.rawValue), .optional(r.errorMessage), .optional(r.deletedAt), .optional(r.modelUsed),
            ])
    }

    public func recording(id: String) throws -> Recording? {
        try db.query("SELECT * FROM recordings WHERE id = ?", [.text(id)]).first.flatMap(Store.recording(from:))
    }

    public func setStatus(_ status: ProcessingStatus, error: String? = nil, for id: String) throws {
        try db.execute("UPDATE recordings SET status = ?, error = ? WHERE id = ?",
                       [.text(status.rawValue), .optional(error), .text(id)])
    }

    public func recordings(matching filter: LibraryFilter = LibraryFilter(), limit: Int = 500) throws -> [Recording] {
        var conditions: [String] = [filter.trashed ? "deleted_at IS NOT NULL" : "deleted_at IS NULL"]
        var params: [DBValue] = []

        if let kind = filter.kind {
            conditions.append("kind = ?"); params.append(.text(kind.rawValue))
        }
        if let language = filter.language {
            conditions.append("language = ?"); params.append(.text(language))
        }
        if let folderID = filter.folderID {
            conditions.append("folder_id = ?"); params.append(.text(folderID))
        }
        if filter.favoritesOnly {
            conditions.append("is_favorite = 1")
        }
        if let range = filter.dateRange {
            conditions.append("created_at >= ? AND created_at < ?")
            params.append(.date(range.start)); params.append(.date(range.end))
        }
        if let tag = filter.tag, !tag.isEmpty {
            // Tags are stored as a JSON array of strings; match the quoted element.
            conditions.append("tags LIKE ? ESCAPE '\\'")
            params.append(.text("%\"\(Store.escapeLike(tag))\"%"))
        }
        let search = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            var clause = "(title LIKE ? ESCAPE '\\' OR tags LIKE ? ESCAPE '\\'"
            let like = "%\(Store.escapeLike(search))%"
            params.append(.text(like)); params.append(.text(like))
            if let fts = SearchQuery.ftsExpression(for: SearchQuery.keywords(in: search, dropStopwords: false), matchAll: true) {
                clause += " OR id IN (SELECT c.recording_id FROM chunks_fts f JOIN chunks c ON c.id = f.rowid WHERE chunks_fts MATCH ?)"
                params.append(.text(fts))
            }
            clause += ")"
            conditions.append(clause)
        }

        let sql = "SELECT * FROM recordings WHERE " + conditions.joined(separator: " AND ")
            + " ORDER BY created_at DESC LIMIT \(max(1, limit))"
        return try db.query(sql, params).compactMap(Store.recording(from:))
    }

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    public func allTags() throws -> [String] {
        let rows = try db.query("SELECT tags FROM recordings WHERE deleted_at IS NULL")
        var set = Set<String>()
        for row in rows { set.formUnion(Store.decodeTags(row.string("tags"))) }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func allLanguages() throws -> [String] {
        try db.query("SELECT DISTINCT language FROM recordings WHERE language IS NOT NULL AND deleted_at IS NULL ORDER BY language")
            .compactMap { $0.string("language") }
    }

    /// Moves a recording to the trash. Audio and transcript are kept until `purge`.
    public func moveToTrash(id: String, at date: Date = Date()) throws {
        try db.execute("UPDATE recordings SET deleted_at = ? WHERE id = ?", [.date(date), .text(id)])
    }

    public func restore(id: String) throws {
        try db.execute("UPDATE recordings SET deleted_at = NULL WHERE id = ?", [.text(id)])
    }

    /// Permanently removes every row belonging to a recording and returns the audio file
    /// name so the caller can delete the encrypted file.
    @discardableResult
    public func purge(id: String) throws -> String? {
        try db.transaction {
            let fileName = try recording(id: id)?.fileName
            // Explicit deletes (rather than relying on cascades alone) so the FTS triggers
            // are guaranteed to run for every chunk.
            try db.execute("DELETE FROM chunks WHERE recording_id = ?", [.text(id)])
            try db.execute("DELETE FROM segments WHERE recording_id = ?", [.text(id)])
            try db.execute("DELETE FROM speakers WHERE recording_id = ?", [.text(id)])
            try db.execute("DELETE FROM summaries WHERE recording_id = ?", [.text(id)])
            try db.execute("DELETE FROM tasks WHERE recording_id = ?", [.text(id)])
            try db.execute("DELETE FROM recordings WHERE id = ?", [.text(id)])
            return fileName
        }
    }

    /// Shrinks the database and truncates the write-ahead log after deletions, so removed
    /// content is not left behind in free pages or the WAL file.
    public func compactAfterDeletion() throws {
        // FTS5 normally keeps the words of deleted rows in older index segments until
        // they happen to be merged. 'optimize' rewrites the index as a single segment
        // containing live rows only, so deleted words are really gone before VACUUM.
        try db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES ('optimize')")
        _ = try? db.query("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.execute("VACUUM")
        _ = try? db.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Folders

    public func folders() throws -> [Folder] {
        try db.query("SELECT * FROM folders ORDER BY name COLLATE NOCASE").compactMap { row in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            return Folder(id: id, name: name, createdAt: row.date("created_at") ?? Date())
        }
    }

    public func save(_ folder: Folder) throws {
        try db.execute("""
            INSERT INTO folders (id, name, created_at) VALUES (?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name
            """, [.text(folder.id), .text(folder.name), .date(folder.createdAt)])
    }

    public func deleteFolder(id: String) throws {
        try db.transaction {
            try db.execute("UPDATE recordings SET folder_id = NULL WHERE folder_id = ?", [.text(id)])
            try db.execute("DELETE FROM folders WHERE id = ?", [.text(id)])
        }
    }

    // MARK: - Transcript

    private static func segment(from row: DBRow) -> TranscriptSegment? {
        guard let id = row.int("id"), let recordingID = row.string("recording_id") else { return nil }
        return TranscriptSegment(
            id: id, recordingID: recordingID, index: Int(row.int("idx") ?? 0),
            start: row.double("start_s") ?? 0, end: row.double("end_s") ?? 0,
            text: row.string("text") ?? "", speakerID: row.string("speaker_id"), isEdited: row.bool("edited"))
    }

    /// Replaces the whole transcript of a recording and rebuilds its search chunks.
    public func replaceTranscript(recordingID: String, segments: [RawSegment], language: String?) throws {
        try db.transaction {
            try db.execute("DELETE FROM segments WHERE recording_id = ?", [.text(recordingID)])
            for (index, segment) in segments.enumerated() {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try db.execute(
                    "INSERT INTO segments (recording_id, idx, start_s, end_s, text) VALUES (?,?,?,?,?)",
                    [.text(recordingID), .int(Int64(index)), .double(segment.start), .double(segment.end), .text(text)])
            }
            if let language {
                try db.execute("UPDATE recordings SET language = ? WHERE id = ?", [.text(language), .text(recordingID)])
            }
            try rebuildChunks(recordingID: recordingID)
        }
    }

    public func segments(recordingID: String) throws -> [TranscriptSegment] {
        try db.query("SELECT * FROM segments WHERE recording_id = ? ORDER BY idx", [.text(recordingID)])
            .compactMap(Store.segment(from:))
    }

    /// Short text for list rows: the summary overview if there is one, otherwise the
    /// opening of the transcript.
    public func previewText(recordingID: String) throws -> String? {
        if let overview = try summary(recordingID: recordingID)?.overview, !overview.isEmpty { return overview }
        let opening = try db.query("SELECT text FROM segments WHERE recording_id = ? ORDER BY idx LIMIT 3", [.text(recordingID)])
            .compactMap { $0.string("text") }.joined(separator: " ")
        return opening.isEmpty ? nil : opening
    }

    public func transcriptText(recordingID: String) throws -> String {
        try segments(recordingID: recordingID).map(\.text).joined(separator: " ")
    }

    /// Manual correction of one segment. The search index is rebuilt so that the corrected
    /// wording is what search and the memory assistant see.
    public func updateSegmentText(id: Int64, text: String) throws {
        try db.transaction {
            guard let row = try db.query("SELECT recording_id FROM segments WHERE id = ?", [.int(id)]).first,
                  let recordingID = row.string("recording_id") else { return }
            try db.execute("UPDATE segments SET text = ?, edited = 1 WHERE id = ?", [.text(text), .int(id)])
            try rebuildChunks(recordingID: recordingID)
        }
    }

    public func assignSpeaker(_ speakerID: String?, toSegment id: Int64) throws {
        try db.execute("UPDATE segments SET speaker_id = ? WHERE id = ?", [.optional(speakerID), .int(id)])
    }

    private func rebuildChunks(recordingID: String) throws {
        try db.execute("DELETE FROM chunks WHERE recording_id = ?", [.text(recordingID)])
        let current = try segments(recordingID: recordingID)
        for chunk in Chunker.chunks(from: current) {
            try db.execute("INSERT INTO chunks (recording_id, start_s, end_s, text) VALUES (?,?,?,?)",
                           [.text(recordingID), .double(chunk.start), .double(chunk.end), .text(chunk.text)])
        }
    }

    public func chunks(recordingID: String) throws -> [TranscriptChunk] {
        try db.query("SELECT * FROM chunks WHERE recording_id = ? ORDER BY start_s", [.text(recordingID)]).compactMap { row in
            guard let id = row.int("id") else { return nil }
            return TranscriptChunk(id: id, recordingID: recordingID, start: row.double("start_s") ?? 0,
                                   end: row.double("end_s") ?? 0, text: row.string("text") ?? "")
        }
    }

    // MARK: - Speakers

    public func speakers(recordingID: String) throws -> [Speaker] {
        try db.query("SELECT * FROM speakers WHERE recording_id = ? ORDER BY label", [.text(recordingID)]).compactMap { row in
            guard let id = row.string("id"), let label = row.string("label") else { return nil }
            return Speaker(id: id, recordingID: recordingID, label: label, name: row.string("name"))
        }
    }

    public func save(_ speaker: Speaker) throws {
        try db.execute("""
            INSERT INTO speakers (id, recording_id, label, name) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET label = excluded.label, name = excluded.name
            """, [.text(speaker.id), .text(speaker.recordingID), .text(speaker.label), .optional(speaker.name)])
    }

    /// Creates the next generic speaker ("Speaker 3") for a recording.
    public func addSpeaker(recordingID: String) throws -> Speaker {
        let count = try db.scalarInt("SELECT COUNT(*) FROM speakers WHERE recording_id = ?", [.text(recordingID)])
        let speaker = Speaker(recordingID: recordingID, label: "Speaker \(count + 1)")
        try save(speaker)
        return speaker
    }

    public func deleteSpeaker(id: String) throws {
        try db.transaction {
            try db.execute("UPDATE segments SET speaker_id = NULL WHERE speaker_id = ?", [.text(id)])
            try db.execute("DELETE FROM speakers WHERE id = ?", [.text(id)])
        }
    }

    // MARK: - Summaries

    public func save(_ summary: MeetingSummary, recordingID: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = String(decoding: try encoder.encode(summary), as: UTF8.self)
        try db.execute("""
            INSERT INTO summaries (recording_id, json, created_at) VALUES (?,?,?)
            ON CONFLICT(recording_id) DO UPDATE SET json = excluded.json, created_at = excluded.created_at
            """, [.text(recordingID), .text(json), .date(summary.createdAt)])
    }

    public func summary(recordingID: String) throws -> MeetingSummary? {
        guard let json = try db.query("SELECT json FROM summaries WHERE recording_id = ?", [.text(recordingID)])
            .first?.string("json"), let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(MeetingSummary.self, from: data)
    }

    // MARK: - Tasks

    private static func task(from row: DBRow) -> TaskItem? {
        guard let id = row.string("id"), let title = row.string("title") else { return nil }
        return TaskItem(
            id: id, recordingID: row.string("recording_id"), title: title, owner: row.string("owner"),
            dueAt: row.date("due_at"), dueText: row.string("due_text"), isDone: row.bool("is_done"),
            createdAt: row.date("created_at") ?? Date(), sourceStart: row.double("source_start"),
            origin: TaskOrigin(rawValue: row.string("origin") ?? "") ?? .manual)
    }

    public func save(_ task: TaskItem) throws {
        try db.execute("""
            INSERT INTO tasks (id, recording_id, title, owner, due_at, due_text, is_done, created_at, source_start, origin)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                title=excluded.title, owner=excluded.owner, due_at=excluded.due_at, due_text=excluded.due_text,
                is_done=excluded.is_done, source_start=excluded.source_start
            """, [
                .text(task.id), .optional(task.recordingID), .text(task.title), .optional(task.owner),
                .optional(task.dueAt), .optional(task.dueText), .bool(task.isDone), .date(task.createdAt),
                .optional(task.sourceStart), .text(task.origin.rawValue),
            ])
    }

    public enum TaskScope: Sendable { case open, completed, all }

    /// Tasks of non-trashed recordings plus manual tasks.
    public func tasks(_ scope: TaskScope = .all, recordingID: String? = nil, createdIn range: DateInterval? = nil) throws -> [TaskItem] {
        var conditions = ["(t.recording_id IS NULL OR r.deleted_at IS NULL)"]
        var params: [DBValue] = []
        switch scope {
        case .open: conditions.append("t.is_done = 0")
        case .completed: conditions.append("t.is_done = 1")
        case .all: break
        }
        if let recordingID {
            conditions.append("t.recording_id = ?"); params.append(.text(recordingID))
        }
        if let range {
            conditions.append("COALESCE(r.created_at, t.created_at) >= ? AND COALESCE(r.created_at, t.created_at) < ?")
            params.append(.date(range.start)); params.append(.date(range.end))
        }
        let sql = """
            SELECT t.* FROM tasks t LEFT JOIN recordings r ON r.id = t.recording_id
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY t.is_done, t.due_at IS NULL, t.due_at, t.created_at DESC
            """
        return try db.query(sql, params).compactMap(Store.task(from:))
    }

    public func setTaskDone(_ done: Bool, id: String) throws {
        try db.execute("UPDATE tasks SET is_done = ? WHERE id = ?", [.bool(done), .text(id)])
    }

    public func deleteTask(id: String) throws {
        try db.execute("DELETE FROM tasks WHERE id = ?", [.text(id)])
    }

    /// Replaces the automatically extracted tasks of a recording. Tasks the user already
    /// completed, and manual tasks, are left alone.
    public func replaceExtractedTasks(recordingID: String, with tasks: [TaskItem]) throws {
        try db.transaction {
            let kept = try db.query(
                "SELECT title FROM tasks WHERE recording_id = ? AND (origin = 'manual' OR is_done = 1)",
                [.text(recordingID)]).compactMap { $0.string("title")?.lowercased() }
            try db.execute("DELETE FROM tasks WHERE recording_id = ? AND origin = 'extracted' AND is_done = 0",
                           [.text(recordingID)])
            for task in tasks where !kept.contains(task.title.lowercased()) {
                try save(task)
            }
        }
    }

    // MARK: - Templates

    public func customTemplates() throws -> [SummaryTemplate] {
        try db.query("SELECT * FROM templates ORDER BY name COLLATE NOCASE").compactMap { row in
            guard let id = row.string("id"), let name = row.string("name") else { return nil }
            return SummaryTemplate(id: id, name: name, instructions: row.string("instructions") ?? "", isBuiltIn: false)
        }
    }

    public func allTemplates() throws -> [SummaryTemplate] {
        try SummaryTemplate.builtIns + customTemplates()
    }

    public func template(id: String) throws -> SummaryTemplate {
        try allTemplates().first { $0.id == id } ?? .meeting
    }

    public func save(_ template: SummaryTemplate) throws {
        guard !template.isBuiltIn else { return }
        try db.execute("""
            INSERT INTO templates (id, name, instructions) VALUES (?,?,?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, instructions = excluded.instructions
            """, [.text(template.id), .text(template.name), .text(template.instructions)])
    }

    public func deleteTemplate(id: String) throws {
        try db.execute("DELETE FROM templates WHERE id = ?", [.text(id)])
    }

    // MARK: - Search

    /// Full-text search over transcript chunks of non-trashed recordings.
    /// - Parameter ftsQuery: an FTS5 MATCH expression, see `SearchQuery.ftsExpression`.
    public func searchChunks(ftsQuery: String, in range: DateInterval? = nil, limit: Int = 8) throws -> [ChunkHit] {
        var sql = """
            SELECT c.id, c.recording_id, c.start_s, c.end_s, c.text, r.title, r.created_at,
                   bm25(chunks_fts) AS rank,
                   snippet(chunks_fts, 0, '', '', '…', 24) AS snip
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN recordings r ON r.id = c.recording_id
            WHERE chunks_fts MATCH ? AND r.deleted_at IS NULL
            """
        var params: [DBValue] = [.text(ftsQuery)]
        if let range {
            sql += " AND r.created_at >= ? AND r.created_at < ?"
            params.append(.date(range.start)); params.append(.date(range.end))
        }
        sql += " ORDER BY rank LIMIT \(max(1, limit))"
        return try db.query(sql, params).compactMap { row in
            guard let id = row.int("id"), let recordingID = row.string("recording_id") else { return nil }
            let chunk = TranscriptChunk(id: id, recordingID: recordingID, start: row.double("start_s") ?? 0,
                                        end: row.double("end_s") ?? 0, text: row.string("text") ?? "")
            return ChunkHit(chunk: chunk, recordingTitle: row.string("title") ?? "",
                            recordingDate: row.date("created_at") ?? Date(),
                            rank: row.double("rank") ?? 0, snippet: row.string("snip") ?? "")
        }
    }

    // MARK: - Network log

    /// Records a network request made by the app. The only caller is the model downloader.
    public func logNetwork(host: String, purpose: String, bytes: Int64, at date: Date = Date()) throws {
        try db.execute("INSERT INTO network_log (at, host, purpose, bytes) VALUES (?,?,?,?)",
                       [.date(date), .text(host), .text(purpose), .int(bytes)])
    }

    public func networkEvents(limit: Int = 100) throws -> [NetworkEvent] {
        try db.query("SELECT * FROM network_log ORDER BY at DESC LIMIT \(max(1, limit))").compactMap { row in
            guard let id = row.int("id") else { return nil }
            return NetworkEvent(id: id, at: row.date("at") ?? Date(), host: row.string("host") ?? "",
                                purpose: row.string("purpose") ?? "", bytes: row.int("bytes") ?? 0)
        }
    }

    // MARK: - Benchmarks

    public func save(_ benchmark: BenchmarkResult) throws {
        try db.execute("""
            INSERT INTO benchmarks (model_id, rate, measured_at, detail) VALUES (?,?,?,?)
            ON CONFLICT(model_id) DO UPDATE SET rate = excluded.rate, measured_at = excluded.measured_at, detail = excluded.detail
            """, [.text(benchmark.modelID), .double(benchmark.rate), .date(benchmark.measuredAt), .text(benchmark.detail)])
    }

    public func benchmark(modelID: String) throws -> BenchmarkResult? {
        try db.query("SELECT * FROM benchmarks WHERE model_id = ?", [.text(modelID)]).first.map { row in
            BenchmarkResult(modelID: modelID, rate: row.double("rate") ?? 0,
                            measuredAt: row.date("measured_at") ?? Date(), detail: row.string("detail") ?? "")
        }
    }

    // MARK: - Stats & retention

    public func stats() throws -> StorageStats {
        StorageStats(
            recordings: Int(try db.scalarInt("SELECT COUNT(*) FROM recordings WHERE deleted_at IS NULL")),
            trashed: Int(try db.scalarInt("SELECT COUNT(*) FROM recordings WHERE deleted_at IS NOT NULL")),
            segments: Int(try db.scalarInt("SELECT COUNT(*) FROM segments")),
            summaries: Int(try db.scalarInt("SELECT COUNT(*) FROM summaries")),
            tasks: Int(try db.scalarInt("SELECT COUNT(*) FROM tasks")),
            totalAudioBytes: try db.scalarInt("SELECT COALESCE(SUM(file_size), 0) FROM recordings"),
            totalDuration: Double(try db.scalarInt("SELECT COALESCE(SUM(duration), 0) FROM recordings WHERE deleted_at IS NULL")))
    }

    /// Recordings that the retention settings say should now be removed for good.
    /// - Parameters:
    ///   - trashDays: days a trashed recording is kept before permanent deletion.
    ///   - retentionDays: if set, non-favourite recordings older than this are removed as well.
    public func recordingsDueForPurge(now: Date = Date(), trashDays: Int, retentionDays: Int?) throws -> [Recording] {
        var result = try db.query(
            "SELECT * FROM recordings WHERE deleted_at IS NOT NULL AND deleted_at < ?",
            [.date(now.addingTimeInterval(-Double(trashDays) * 86_400))]).compactMap(Store.recording(from:))
        if let retentionDays, retentionDays > 0 {
            result += try db.query(
                "SELECT * FROM recordings WHERE deleted_at IS NULL AND is_favorite = 0 AND created_at < ?",
                [.date(now.addingTimeInterval(-Double(retentionDays) * 86_400))]).compactMap(Store.recording(from:))
        }
        return result
    }

    /// Removes every row from every table. Used by "Erase all data".
    public func eraseEverything() throws {
        try db.transaction {
            for table in ["chunks", "segments", "speakers", "summaries", "tasks", "recordings", "folders",
                          "templates", "network_log", "benchmarks"] {
                try db.execute("DELETE FROM \(table)")
            }
        }
        try compactAfterDeletion()
    }
}
