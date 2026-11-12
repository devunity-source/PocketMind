import Foundation

public enum RecordingKind: String, Codable, CaseIterable, Sendable {
    case meeting, call, note, imported

    public var label: String {
        switch self {
        case .meeting: "Meetings"
        case .call: "Calls"
        case .note: "Notes"
        case .imported: "Imported"
        }
    }
}

public enum ProcessingStatus: String, Codable, Sendable {
    /// Audio saved, nothing else done yet.
    case recorded
    case transcribing
    case transcribed
    case summarizing
    case ready
    case failed
}

public enum RecordingQuality: String, Codable, CaseIterable, Sendable {
    case compact, standard, high

    public var label: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .high: "High quality"
        }
    }

    public var sampleRate: Double {
        switch self {
        case .compact: 16_000
        case .standard: 24_000
        case .high: 44_100
        }
    }

    /// AAC bit rate in bits per second (mono).
    public var bitRate: Int {
        switch self {
        case .compact: 24_000
        case .standard: 48_000
        case .high: 96_000
        }
    }

    public var megabytesPerHour: Double { Double(bitRate) / 8.0 * 3600.0 / 1_000_000.0 }
}

public struct Recording: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var duration: Double
    /// File name (not path) of the encrypted audio inside the vault's audio directory.
    public var fileName: String
    public var fileSize: Int64
    public var quality: RecordingQuality
    public var language: String?
    public var kind: RecordingKind
    public var folderID: String?
    public var isFavorite: Bool
    public var tags: [String]
    public var status: ProcessingStatus
    public var errorMessage: String?
    public var deletedAt: Date?
    public var modelUsed: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        duration: Double = 0,
        fileName: String,
        fileSize: Int64 = 0,
        quality: RecordingQuality = .standard,
        language: String? = nil,
        kind: RecordingKind = .meeting,
        folderID: String? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        status: ProcessingStatus = .recorded,
        errorMessage: String? = nil,
        deletedAt: Date? = nil,
        modelUsed: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.fileSize = fileSize
        self.quality = quality
        self.language = language
        self.kind = kind
        self.folderID = folderID
        self.isFavorite = isFavorite
        self.tags = tags
        self.status = status
        self.errorMessage = errorMessage
        self.deletedAt = deletedAt
        self.modelUsed = modelUsed
    }
}

public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A segment as produced by a transcription engine, before it is stored.
public struct RawSegment: Hashable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct TranscriptSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64
    public var recordingID: String
    public var index: Int
    public var start: Double
    public var end: Double
    public var text: String
    public var speakerID: String?
    public var isEdited: Bool

    public init(id: Int64, recordingID: String, index: Int, start: Double, end: Double,
                text: String, speakerID: String? = nil, isEdited: Bool = false) {
        self.id = id
        self.recordingID = recordingID
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.speakerID = speakerID
        self.isEdited = isEdited
    }
}

public struct Speaker: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var recordingID: String
    /// Stable generic label, e.g. "Speaker 1".
    public var label: String
    /// Optional name chosen by the user.
    public var name: String?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return label
    }

    public init(id: String = UUID().uuidString, recordingID: String, label: String, name: String? = nil) {
        self.id = id
        self.recordingID = recordingID
        self.label = label
        self.name = name
    }
}

public struct TranscriptChunk: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var recordingID: String
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: Int64, recordingID: String, start: Double, end: Double, text: String) {
        self.id = id
        self.recordingID = recordingID
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct ActionItemDraft: Hashable, Codable, Sendable {
    public var task: String
    public var owner: String?
    public var due: String?

    public init(task: String, owner: String? = nil, due: String? = nil) {
        self.task = task
        self.owner = owner
        self.due = due
    }
}

public struct DeadlineNote: Hashable, Codable, Sendable {
    public var what: String
    public var when: String

    public init(what: String, when: String) {
        self.what = what
        self.when = when
    }
}

/// Structured result of summarising one recording.
public struct MeetingSummary: Hashable, Codable, Sendable {
    public var title: String
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItemDraft]
    public var deadlines: [DeadlineNote]
    public var facts: [String]
    public var followUpQuestions: [String]
    /// "llm:<model id>" or "extractive".
    public var engine: String
    public var templateID: String
    public var createdAt: Date

    public init(
        title: String = "",
        overview: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItemDraft] = [],
        deadlines: [DeadlineNote] = [],
        facts: [String] = [],
        followUpQuestions: [String] = [],
        engine: String = "extractive",
        templateID: String = SummaryTemplate.meeting.id,
        createdAt: Date = Date()
    ) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.deadlines = deadlines
        self.facts = facts
        self.followUpQuestions = followUpQuestions
        self.engine = engine
        self.templateID = templateID
        self.createdAt = createdAt
    }

    public var isFromLanguageModel: Bool { engine.hasPrefix("llm:") }
}

public enum TaskOrigin: String, Codable, Sendable {
    case extracted, manual
}

public struct TaskItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var recordingID: String?
    public var title: String
    public var owner: String?
    public var dueAt: Date?
    /// The deadline exactly as it was phrased in the recording ("by next Friday").
    public var dueText: String?
    public var isDone: Bool
    public var createdAt: Date
    public var sourceStart: Double?
    public var origin: TaskOrigin

    public init(
        id: String = UUID().uuidString,
        recordingID: String? = nil,
        title: String,
        owner: String? = nil,
        dueAt: Date? = nil,
        dueText: String? = nil,
        isDone: Bool = false,
        createdAt: Date = Date(),
        sourceStart: Double? = nil,
        origin: TaskOrigin = .manual
    ) {
        self.id = id
        self.recordingID = recordingID
        self.title = title
        self.owner = owner
        self.dueAt = dueAt
        self.dueText = dueText
        self.isDone = isDone
        self.createdAt = createdAt
        self.sourceStart = sourceStart
        self.origin = origin
    }
}

public struct SummaryTemplate: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// Extra guidance appended to the base summarisation prompt.
    public var instructions: String
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, instructions: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }

    public static let meeting = SummaryTemplate(
        id: "builtin.meeting", name: "Meeting",
        instructions: "This is a meeting. Focus on what was discussed, what was decided, and who committed to what.",
        isBuiltIn: true)

    public static let call = SummaryTemplate(
        id: "builtin.call", name: "Phone call",
        instructions: "This is a call between a small number of people. Capture commitments, agreed next steps and any dates.",
        isBuiltIn: true)

    public static let note = SummaryTemplate(
        id: "builtin.note", name: "Voice note",
        instructions: "This is a personal voice note from one speaker. Capture the ideas and any to-dos the speaker sets for themself.",
        isBuiltIn: true)

    public static let lecture = SummaryTemplate(
        id: "builtin.lecture", name: "Lecture / talk",
        instructions: "This is a lecture or talk. Focus on the main concepts and facts. Decisions and action items are usually empty.",
        isBuiltIn: true)

    public static let builtIns: [SummaryTemplate] = [.meeting, .call, .note, .lecture]
}

public struct NetworkEvent: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var at: Date
    public var host: String
    public var purpose: String
    public var bytes: Int64

    public init(id: Int64, at: Date, host: String, purpose: String, bytes: Int64) {
        self.id = id
        self.at = at
        self.host = host
        self.purpose = purpose
        self.bytes = bytes
    }
}

public struct BenchmarkResult: Hashable, Sendable {
    public var modelID: String
    /// Whisper: processing seconds per audio second. LLM: seconds per generated token.
    public var rate: Double
    public var measuredAt: Date
    public var detail: String

    public init(modelID: String, rate: Double, measuredAt: Date = Date(), detail: String = "") {
        self.modelID = modelID
        self.rate = rate
        self.measuredAt = measuredAt
        self.detail = detail
    }
}

public struct StorageStats: Hashable, Sendable {
    public var recordings: Int
    public var trashed: Int
    public var segments: Int
    public var summaries: Int
    public var tasks: Int
    public var totalAudioBytes: Int64
    public var totalDuration: Double
}
