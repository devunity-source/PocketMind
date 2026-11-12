import Foundation

public enum TranscriptExporter {
    static func timestamp(_ seconds: Double) -> String { MemoryService.timestamp(seconds) }

    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func plainText(recording: Recording, segments: [TranscriptSegment], speakers: [Speaker] = [],
                                 timeZone: TimeZone = .current) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        var lines = [recording.title, dateString(recording.createdAt, timeZone: timeZone), ""]
        for segment in segments {
            var line = "[\(timestamp(segment.start))] "
            if let id = segment.speakerID, let name = names[id] { line += "\(name): " }
            lines.append(line + segment.text)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func markdown(recording: Recording, segments: [TranscriptSegment], speakers: [Speaker] = [],
                                summary: MeetingSummary? = nil, timeZone: TimeZone = .current) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        var out = "# \(recording.title)\n\n"
        out += "- **Date:** \(dateString(recording.createdAt, timeZone: timeZone))\n"
        out += "- **Duration:** \(timestamp(recording.duration))\n"
        if let language = recording.language { out += "- **Language:** \(SupportedLanguage.name(for: language))\n" }
        if !recording.tags.isEmpty { out += "- **Tags:** \(recording.tags.joined(separator: ", "))\n" }

        if let summary {
            func section(_ title: String, _ items: [String]) {
                guard !items.isEmpty else { return }
                out += "\n## \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if !summary.overview.isEmpty { out += "\n## Summary\n\n\(summary.overview)\n" }
            section("Key points", summary.keyPoints)
            section("Decisions", summary.decisions)
            section("Action items", summary.actionItems.map { item in
                var line = "[ ] \(item.task)"
                if let owner = item.owner { line += " — \(owner)" }
                if let due = item.due { line += " (due \(due))" }
                return line
            })
            section("Deadlines", summary.deadlines.map { "\($0.what) — \($0.when)" })
            section("Important facts", summary.facts)
            section("Follow-up questions", summary.followUpQuestions)
            if !summary.isFromLanguageModel {
                out += "\n_Summary produced without a language model: sentences are quoted from the transcript._\n"
            }
        }

        out += "\n## Transcript\n\n"
        for segment in segments {
            var line = "**\(timestamp(segment.start))** "
            if let id = segment.speakerID, let name = names[id] { line += "_\(name):_ " }
            out += line + segment.text + "\n\n"
        }
        return out
    }

    /// A file-system-safe base name for exported files.
    public static func fileName(for recording: Recording) -> String {
        let allowed = recording.title.map { character -> Character in
            character.isLetter || character.isNumber || character == " " || character == "-" ? character : "_"
        }
        let trimmed = String(allowed).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Recording" : String(trimmed.prefix(60))
    }
}

/// Small crash-safe record written next to an in-progress recording. If the app is killed
/// or the phone restarts mid-recording, the audio captured so far is found again on the
/// next launch and imported into the library instead of being lost.
public struct RecoveryJournal: Codable, Hashable, Sendable {
    public var recordingID: String
    public var title: String
    public var startedAt: Date
    public var audioFileName: String
    public var quality: RecordingQuality
    public var kind: RecordingKind
    public var tags: [String]

    public init(recordingID: String, title: String, startedAt: Date, audioFileName: String,
                quality: RecordingQuality, kind: RecordingKind, tags: [String] = []) {
        self.recordingID = recordingID
        self.title = title
        self.startedAt = startedAt
        self.audioFileName = audioFileName
        self.quality = quality
        self.kind = kind
        self.tags = tags
    }

    public static let fileExtension = "journal"

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = directory.appendingPathComponent(recordingID).appendingPathExtension(RecoveryJournal.fileExtension)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func remove(recordingID: String, from directory: URL) {
        let url = directory.appendingPathComponent(recordingID).appendingPathExtension(fileExtension)
        try? FileManager.default.removeItem(at: url)
    }

    /// Journals left behind by recordings that never finished cleanly.
    public static func pending(in directory: URL) -> [RecoveryJournal] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }
            .compactMap { try? decoder.decode(RecoveryJournal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }
}
