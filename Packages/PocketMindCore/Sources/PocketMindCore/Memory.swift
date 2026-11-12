import Foundation

public struct SourceReference: Identifiable, Hashable, Sendable {
    public var id: String { "\(label)-\(recordingID)-\(Int(start))" }
    /// Citation label used in the answer text, e.g. "S1".
    public var label: String
    public var recordingID: String
    public var recordingTitle: String
    public var recordingDate: Date
    /// Position inside the recording, in seconds.
    public var start: Double
    public var snippet: String
    /// True when the answer text actually cites this source.
    public var isCited: Bool
}

public struct MemoryAnswer: Hashable, Sendable {
    public var text: String
    public var sources: [SourceReference]
    /// "llm:<model id>" when a language model wrote the answer, "search" when the answer
    /// is a plain listing of matching passages.
    public var engine: String
    /// False when nothing relevant was found and no model was consulted.
    public var foundEvidence: Bool
}

/// Retrieval-augmented question answering over the user's recordings, entirely local:
/// FTS5 retrieval → context assembly → (optional) local language model → cited answer.
public struct MemoryService: Sendable {
    public let store: Store
    public let llm: (any LanguageModelEngine)?
    public var calendar: Calendar

    public init(store: Store, llm: (any LanguageModelEngine)?, calendar: Calendar = .current) {
        self.store = store
        self.llm = llm
        self.calendar = calendar
    }

    public static let suggestedQuestions = [
        "What did I discuss yesterday?",
        "What tasks did I promise to complete?",
        "Summarize my meetings from last week.",
        "What deadlines were discussed this month?",
    ]

    struct Evidence {
        var sources: [SourceReference] = []
        var passages: [String] = []

        mutating func add(recordingID: String, title: String, date: Date, start: Double, text: String, snippet: String) {
            let label = "S\(sources.count + 1)"
            sources.append(SourceReference(label: label, recordingID: recordingID, recordingTitle: title,
                                           recordingDate: date, start: start, snippet: snippet, isCited: false))
            passages.append(text)
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter.string(from: date)
    }

    /// Gathers the passages that will ground the answer.
    func retrieve(_ query: ParsedQuery, limit: Int) throws -> Evidence {
        var evidence = Evidence()

        // 1. Structured data for task / deadline questions.
        if query.intent == .tasks || query.intent == .deadlines {
            var tasks = try store.tasks(query.intent == .tasks ? .open : .all, createdIn: query.dateRange)
            if query.intent == .deadlines {
                tasks = tasks.filter { $0.dueAt != nil || $0.dueText != nil }
            }
            if !query.keywords.isEmpty {
                let wanted = Set(query.keywords.map(SearchQuery.stem))
                let filtered = tasks.filter { task in
                    !Set(SearchQuery.keywords(in: task.title, dropStopwords: false).map(SearchQuery.stem)).isDisjoint(with: wanted)
                }
                if !filtered.isEmpty { tasks = filtered }
            }
            for task in tasks.prefix(limit) {
                guard let recordingID = task.recordingID, let recording = try store.recording(id: recordingID) else { continue }
                var line = (task.isDone ? "Completed task: " : "Open task: ") + task.title
                if let owner = task.owner { line += " (owner: \(owner))" }
                if let dueText = task.dueText { line += " (due: \(dueText))" }
                evidence.add(recordingID: recording.id, title: recording.title, date: recording.createdAt,
                             start: task.sourceStart ?? 0, text: line, snippet: task.title)
            }
        }

        // 2. Lexical search over transcript chunks.
        if evidence.sources.count < limit,
           let fts = SearchQuery.ftsExpression(for: query.keywords) {
            let hits = try store.searchChunks(ftsQuery: fts, in: query.dateRange, limit: limit - evidence.sources.count)
            for hit in hits {
                evidence.add(recordingID: hit.chunk.recordingID, title: hit.recordingTitle, date: hit.recordingDate,
                             start: hit.chunk.start, text: hit.chunk.text, snippet: hit.snippet)
            }
        }

        // 3. Questions with a time window but no topic ("what did I discuss yesterday?"):
        //    fall back to the summaries of the recordings in that window.
        if evidence.sources.isEmpty, query.dateRange != nil || query.intent == .overview {
            var filter = LibraryFilter()
            filter.dateRange = query.dateRange
            for recording in try store.recordings(matching: filter, limit: limit) {
                if let summary = try store.summary(recordingID: recording.id), !summary.overview.isEmpty {
                    var text = summary.overview
                    if !summary.decisions.isEmpty { text += " Decisions: " + summary.decisions.joined(separator: "; ") + "." }
                    evidence.add(recordingID: recording.id, title: recording.title, date: recording.createdAt,
                                 start: 0, text: text, snippet: summary.overview)
                } else if let first = try store.chunks(recordingID: recording.id).first {
                    evidence.add(recordingID: recording.id, title: recording.title, date: recording.createdAt,
                                 start: first.start, text: first.text, snippet: String(first.text.prefix(160)))
                }
            }
        }
        return evidence
    }

    /// Answers a question from the recordings.
    /// - Parameter onToken: streamed pieces of the answer while a language model writes it.
    public func answer(question: String, now: Date = Date(),
                       onToken: @escaping @Sendable (String) -> Void = { _ in },
                       isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MemoryAnswer {
        let query = QueryParser.parse(question, now: now, calendar: calendar)
        var evidence = try retrieve(query, limit: 6)

        guard !evidence.sources.isEmpty else {
            let scope = query.dateLabel.map { " from \($0)" } ?? ""
            return MemoryAnswer(
                text: "I couldn't find anything in your recordings\(scope) about that.",
                sources: [], engine: "search", foundEvidence: false)
        }

        guard let llm else {
            return MemoryAnswer(text: listing(evidence), sources: evidence.sources, engine: "search", foundEvidence: true)
        }

        // Fit the passages into the context window, most relevant first.
        let outputTokens = 400
        let budget = PromptBuilder.characterBudget(
            tokens: max(400, llm.contextTokens - outputTokens - 350), sample: evidence.passages.joined(separator: " "))
        var context = ""
        var used = 0
        for (source, passage) in zip(evidence.sources, evidence.passages) {
            let header = "[\(source.label)] \(source.recordingTitle) — \(dateString(source.recordingDate)) — at \(MemoryService.timestamp(source.start))"
            let entry = header + "\n" + passage + "\n\n"
            if context.count + entry.count > budget, used > 0 { break }
            context += entry.count > budget ? String(entry.prefix(budget)) : entry
            used += 1
        }
        evidence.sources = Array(evidence.sources.prefix(used))

        let messages = PromptBuilder.memoryMessages(question: question, context: context, dateLabel: query.dateLabel)
        let text = try await llm.generate(
            messages: messages, options: GenerationOptions(maxTokens: outputTokens, temperature: 0.2)
        ) { piece in
            onToken(piece)
            return !isCancelled()
        }

        let cited = MemoryService.citedLabels(in: text)
        var sources = evidence.sources
        for index in sources.indices { sources[index].isCited = cited.contains(sources[index].label) }
        return MemoryAnswer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources,
                            engine: "llm:\(llm.modelID)", foundEvidence: true)
    }

    /// Answer used when no language model is installed: the matching passages themselves.
    func listing(_ evidence: Evidence) -> String {
        var lines = ["Here is what I found in your recordings:"]
        for source in evidence.sources {
            lines.append("• \(source.snippet) [\(source.label)]")
        }
        return lines.joined(separator: "\n")
    }

    public static func citedLabels(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\[S(\d{1,2})\]"#) else { return [] }
        let ns = text as NSString
        var labels = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            labels.insert("S" + ns.substring(with: match.range(at: 1)))
        }
        return labels
    }
}
