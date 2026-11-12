import Foundation
import XCTest
@testable import PocketMindCore

/// Scripted language model. It performs no I/O of any kind, which is what lets the
/// offline tests prove that summarisation and memory search need no network.
final class FakeLanguageModel: LanguageModelEngine, @unchecked Sendable {
    let modelID = "fake-model"
    let contextTokens: Int
    private let lock = NSLock()
    private var recorded: [[ChatMessage]] = []
    private let responder: @Sendable ([ChatMessage]) -> String

    init(contextTokens: Int = 4096, responder: @escaping @Sendable ([ChatMessage]) -> String) {
        self.contextTokens = contextTokens
        self.responder = responder
    }

    var calls: [[ChatMessage]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ messages: [ChatMessage]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(messages)
    }

    func generate(messages: [ChatMessage], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Bool) async throws -> String {
        record(messages)
        let output = responder(messages)
        _ = onToken(output)
        return output
    }
}

enum Fixtures {
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    static func memoryStore() throws -> Store {
        try Store(path: ":memory:")
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocketmind-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let infrastructureLines = [
        "Okay, let's start the infrastructure sync.",
        "First topic is the Kubernetes staging cluster.",
        "The staging cluster is two versions behind production.",
        "We decided to upgrade the staging cluster next week.",
        "We also agreed to introduce automated security scanning in the CI/CD pipeline.",
        "I will prepare the Terraform changes by Friday.",
        "Alex, can you review the cluster monitoring dashboards?",
        "Maria needs to update the deployment documentation.",
        "That is everything for today, thanks everyone.",
    ]

    @discardableResult
    static func addRecording(to store: Store, title: String, date: Date, lines: [String],
                             kind: RecordingKind = .meeting, language: String? = "en",
                             tags: [String] = []) throws -> Recording {
        let recording = Recording(title: title, createdAt: date, duration: Double(lines.count) * 5,
                                  fileName: UUID().uuidString + ".pmenc", fileSize: 1_000,
                                  language: language, kind: kind, tags: tags, status: .transcribed)
        try store.save(recording)
        let segments = lines.enumerated().map { index, line in
            RawSegment(start: Double(index) * 5, end: Double(index) * 5 + 5, text: line)
        }
        try store.replaceTranscript(recordingID: recording.id, segments: segments, language: language)
        return recording
    }

    static let summaryJSON = """
    {"title": "Infrastructure Sync", "summary": "Discussed the Kubernetes staging cluster upgrade and security scanning.",
     "key_points": ["The staging cluster is two versions behind production."],
     "decisions": ["Upgrade the staging cluster next week.", "Introduce automated security scanning in the CI/CD pipeline."],
     "action_items": [{"task": "Prepare the Terraform changes", "owner": null, "due": "Friday"},
                      {"task": "Review the cluster monitoring dashboards", "owner": "Alex", "due": null}],
     "deadlines": [{"what": "Terraform changes", "when": "Friday"}],
     "facts": [], "follow_up_questions": []}
    """
}
