import Foundation

// MARK: - Prompts

public enum PromptBuilder {
    /// GBNF grammar that forces the model to emit exactly the summary JSON object.
    public static let summaryGrammar = #"""
    root ::= "{" ws "\"title\"" ws ":" ws string "," ws "\"summary\"" ws ":" ws string "," ws "\"key_points\"" ws ":" ws strarr "," ws "\"decisions\"" ws ":" ws strarr "," ws "\"action_items\"" ws ":" ws itemarr "," ws "\"deadlines\"" ws ":" ws dlarr "," ws "\"facts\"" ws ":" ws strarr "," ws "\"follow_up_questions\"" ws ":" ws strarr ws "}"
    strarr ::= "[" ws (string (ws "," ws string)*)? ws "]"
    itemarr ::= "[" ws (item (ws "," ws item)*)? ws "]"
    item ::= "{" ws "\"task\"" ws ":" ws string "," ws "\"owner\"" ws ":" ws nstring "," ws "\"due\"" ws ":" ws nstring ws "}"
    dlarr ::= "[" ws (dl (ws "," ws dl)*)? ws "]"
    dl ::= "{" ws "\"what\"" ws ":" ws string "," ws "\"when\"" ws ":" ws string ws "}"
    nstring ::= string | "null"
    string ::= "\"" char* "\""
    char ::= [^"\\\x7F\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    ws ::= [ \t\n]?
    """#

    static let summarySystem = """
    You turn a transcript into structured notes. Follow these rules strictly:
    - Use ONLY information that is stated in the transcript. Never add outside knowledge.
    - Never invent decisions, tasks, owners, dates or facts. If the transcript does not contain an item of some kind, return an empty list for it.
    - A decision is something the speakers explicitly agreed on. An action item is something a person explicitly said they or someone else will do.
    - "owner" and "due" must be null unless the transcript names them.
    - Write in the same language as the transcript.
    - Reply with a single JSON object and nothing else, using exactly these keys:
    {"title": string, "summary": string, "key_points": [string], "decisions": [string], "action_items": [{"task": string, "owner": string|null, "due": string|null}], "deadlines": [{"what": string, "when": string}], "facts": [string], "follow_up_questions": [string]}
    """

    public static func summaryMessages(transcript: String, title: String, template: SummaryTemplate,
                                       part: Int? = nil, totalParts: Int? = nil) -> [ChatMessage] {
        var user = ""
        if let part, let totalParts, totalParts > 1 {
            user += "This is part \(part) of \(totalParts) of a longer recording. Summarise only this part.\n"
        }
        if !title.isEmpty { user += "Recording title: \(title)\n" }
        if !template.instructions.isEmpty { user += "Guidance: \(template.instructions)\n" }
        user += "\nTranscript:\n\"\"\"\n\(transcript)\n\"\"\"\n\nReturn the JSON object now."
        return [ChatMessage(.system, summarySystem), ChatMessage(.user, user)]
    }

    public static func mergeMessages(notes: String, title: String, template: SummaryTemplate) -> [ChatMessage] {
        var user = "Below are notes taken from consecutive parts of one recording. "
            + "Combine them into one set of notes for the whole recording. Use only what the notes say.\n"
        if !title.isEmpty { user += "Recording title: \(title)\n" }
        if !template.instructions.isEmpty { user += "Guidance: \(template.instructions)\n" }
        user += "\nNotes:\n\"\"\"\n\(notes)\n\"\"\"\n\nReturn the JSON object now."
        return [ChatMessage(.system, summarySystem), ChatMessage(.user, user)]
    }

    static let memorySystem = """
    You answer questions about the user's own recordings. Follow these rules strictly:
    - Use ONLY the numbered sources provided. Never use outside knowledge and never guess.
    - After each statement, cite the source it came from in square brackets, like [S1] or [S2].
    - If the sources do not contain the answer, say that you could not find it in the recordings.
    - Be concise. Answer in the language of the question.
    """

    public static func memoryMessages(question: String, context: String, dateLabel: String?) -> [ChatMessage] {
        var user = "Sources:\n\(context)\n\n"
        if let dateLabel { user += "The question is about recordings from \(dateLabel).\n" }
        user += "Question: \(question)"
        return [ChatMessage(.system, memorySystem), ChatMessage(.user, user)]
    }

    /// Conservative estimate of how many characters fit in a token budget. Non-Latin
    /// scripts tokenise into more tokens per character with current small models.
    public static func characterBudget(tokens: Int, sample: String) -> Int {
        let scalars = sample.unicodeScalars.prefix(400)
        let nonLatin = scalars.filter { $0.value > 0x024F && $0.properties.isAlphabetic }.count
        let ratio = scalars.isEmpty ? 0 : Double(nonLatin) / Double(scalars.count)
        let charactersPerToken = ratio > 0.3 ? 1.6 : 3.0
        return max(400, Int(Double(tokens) * charactersPerToken))
    }
}

// MARK: - Parsing model output

public enum SummaryParser {
    private struct FlexibleString: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let number = try? container.decode(Double.self) {
                value = number == number.rounded() ? String(Int(number)) : String(number)
            } else if let dictionary = try? container.decode([String: FlexibleString].self) {
                value = dictionary.keys.sorted().compactMap { dictionary[$0]?.value }.joined(separator: " — ")
            } else {
                value = ""
            }
        }
    }

    private struct FlexibleItem: Decodable {
        var task = ""
        var owner: String?
        var due: String?

        private struct Keys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
                task = string
                return
            }
            let container = try decoder.container(keyedBy: Keys.self)
            func read(_ names: [String]) -> String? {
                for name in names {
                    guard let key = Keys(stringValue: name) else { continue }
                    if let value = try? container.decode(FlexibleString.self, forKey: key), !value.value.isEmpty {
                        return value.value
                    }
                }
                return nil
            }
            task = read(["task", "title", "action", "item", "what", "description"]) ?? ""
            owner = read(["owner", "assignee", "who", "person"])
            due = read(["due", "deadline", "when", "due_date", "date"])
        }
    }

    private struct Wire: Decodable {
        var title: FlexibleString?
        var summary: FlexibleString?
        var key_points: [FlexibleString]?
        var decisions: [FlexibleString]?
        var action_items: [FlexibleItem]?
        var deadlines: [FlexibleItem]?
        var facts: [FlexibleString]?
        var follow_up_questions: [FlexibleString]?
    }

    /// Parses model output into a summary. Tolerates text around the JSON object, loosely
    /// typed fields, and output that was cut off before the closing braces.
    public static func parse(_ output: String) -> MeetingSummary? {
        guard let start = output.firstIndex(of: "{") else { return nil }
        let candidate = repair(String(output[start...]))
        guard let data = candidate.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }

        func clean(_ items: [FlexibleString]?) -> [String] {
            dedupe((items ?? []).map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        func nullable(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let lowered = text.lowercased()
            let placeholders = ["null", "none", "n/a", "na", "unknown", "not specified", "unspecified", "tbd", "-"]
            return placeholders.contains(lowered) ? nil : text
        }

        let actions = (wire.action_items ?? []).compactMap { item -> ActionItemDraft? in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            return ActionItemDraft(task: task, owner: nullable(item.owner), due: nullable(item.due))
        }
        let deadlines = (wire.deadlines ?? []).compactMap { item -> DeadlineNote? in
            let what = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty, let when = nullable(item.due) else { return nil }
            return DeadlineNote(what: what, when: when)
        }

        return MeetingSummary(
            title: wire.title?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            overview: wire.summary?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            keyPoints: clean(wire.key_points),
            decisions: clean(wire.decisions),
            actionItems: actions,
            deadlines: deadlines,
            facts: clean(wire.facts),
            followUpQuestions: clean(wire.follow_up_questions))
    }

    /// Trims anything after the outermost closing brace, or — when generation stopped
    /// early — closes the open string, arrays and objects so the prefix still decodes.
    static func repair(_ text: String) -> String {
        var stack: [Character] = []
        var inString = false
        var escaped = false
        var result = ""
        for character in text {
            result.append(character)
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                if stack.last == character { stack.removeLast() }
                if stack.isEmpty { return result }
            default: break
            }
        }
        if escaped { result.removeLast() }
        if inString { result.append("\"") }
        // A dangling comma or key without a value cannot be closed cleanly; drop back to
        // the last complete value.
        var trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, last == "," || last == ":" {
            trimmed.removeLast()
            if last == ":" {
                // remove the orphaned key as well
                if let quoteEnd = trimmed.lastIndex(of: "\"") {
                    let before = trimmed[..<quoteEnd]
                    if let quoteStart = before.lastIndex(of: "\"") { trimmed = String(trimmed[..<quoteStart]) }
                }
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed + String(stack.reversed())
    }

    static func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased().filter { $0.isLetter || $0.isNumber }).inserted }
    }
}

// MARK: - Grounding

/// Cheap lexical check that a generated statement is actually supported by the transcript.
/// It cannot prove a statement is right, but it reliably catches items whose wording has
/// no basis in the recording at all.
public enum Grounding {
    static func contentWords(_ text: String) -> [String] {
        SearchQuery.keywords(in: text, dropStopwords: false)
            .filter { $0.count >= 3 && !SearchQuery.stopwords.contains($0) }
            .map(SearchQuery.stem)
    }

    public static func vocabulary(of transcript: String) -> Set<String> {
        Set(contentWords(transcript))
    }

    /// Fraction of the statement's content words that occur in the transcript (0...1).
    public static func support(for statement: String, vocabulary: Set<String>) -> Double {
        let words = contentWords(statement)
        guard !words.isEmpty else { return 1 }
        let hits = words.filter { word in
            vocabulary.contains(word) || vocabulary.contains { $0.count >= 5 && word.count >= 5 && $0.hasPrefix(word.prefix(5)) }
        }
        return Double(hits.count) / Double(words.count)
    }

    /// Drops decisions, action items, deadlines and facts that the transcript does not support.
    public static func filter(_ summary: MeetingSummary, transcript: String, threshold: Double = 0.5) -> MeetingSummary {
        let vocabulary = vocabulary(of: transcript)
        guard !vocabulary.isEmpty else { return summary }

        // If almost none of the output overlaps the transcript, the model most likely wrote
        // in a different language than the recording; a lexical check is meaningless then.
        let everything = ([summary.overview] + summary.keyPoints + summary.decisions
                          + summary.actionItems.map(\.task) + summary.facts).joined(separator: " ")
        if support(for: everything, vocabulary: vocabulary) < 0.25 { return summary }

        var result = summary
        result.decisions = summary.decisions.filter { support(for: $0, vocabulary: vocabulary) >= threshold }
        result.facts = summary.facts.filter { support(for: $0, vocabulary: vocabulary) >= threshold }
        result.actionItems = summary.actionItems.compactMap { item in
            guard support(for: item.task, vocabulary: vocabulary) >= threshold else { return nil }
            var item = item
            if let owner = item.owner, support(for: owner, vocabulary: vocabulary) < 0.5 { item.owner = nil }
            if let due = item.due, support(for: due, vocabulary: vocabulary) < 0.5 { item.due = nil }
            return item
        }
        result.deadlines = summary.deadlines.filter {
            support(for: $0.what, vocabulary: vocabulary) >= threshold && support(for: $0.when, vocabulary: vocabulary) >= 0.5
        }
        return result
    }
}

// MARK: - Due dates

/// Resolves a spoken deadline ("by Friday", "Feb 3", "in two weeks") to a calendar date,
/// relative to when the recording was made. English phrases only; anything it cannot
/// resolve keeps its original wording and simply has no date attached.
public enum DueDateParser {
    static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                         "september", "october", "november", "december"]
    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                              "eight": 8, "nine": 9, "ten": 10, "a": 1, "an": 1]

    public static func parse(_ text: String, relativeTo reference: Date, calendar: Calendar = .current) -> Date? {
        let lowered = " " + text.lowercased() + " "
        let today = calendar.startOfDay(for: reference)
        func plus(_ component: Calendar.Component, _ value: Int) -> Date? {
            calendar.date(byAdding: component, value: value, to: today)
        }

        if let m = QueryParser.firstMatch(#"(\d{4})-(\d{1,2})-(\d{1,2})"#, in: lowered),
           let year = Int(m.groups[0]), let month = Int(m.groups[1]), let day = Int(m.groups[2]) {
            return calendar.date(from: DateComponents(year: year, month: month, day: day))
        }
        if lowered.contains("day after tomorrow") { return plus(.day, 2) }
        if lowered.contains("tomorrow") { return plus(.day, 1) }
        if lowered.contains(" today") || lowered.contains("tonight") || lowered.contains("end of day")
            || lowered.contains(" eod") { return today }

        if let m = QueryParser.firstMatch(#"in (\d+|[a-z]+) (day|week|month)s?"#, in: lowered) {
            if let count = Int(m.groups[0]) ?? numberWords[m.groups[0]] {
                switch m.groups[1] {
                case "day": return plus(.day, count)
                case "week": return plus(.day, count * 7)
                default: return plus(.month, count)
                }
            }
        }

        let monthPattern = "(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\.?"
        var day: Int?, monthName: String?, year: Int?
        if let m = QueryParser.firstMatch("\\b\(monthPattern) (\\d{1,2})(?:st|nd|rd|th)?(?:,? (\\d{4}))?", in: lowered) {
            monthName = m.groups[0]; day = Int(m.groups[1]); year = Int(m.groups[2])
        } else if let m = QueryParser.firstMatch("\\b(\\d{1,2})(?:st|nd|rd|th)?(?: of)? \(monthPattern)(?:,? (\\d{4}))?", in: lowered) {
            day = Int(m.groups[0]); monthName = m.groups[1]; year = Int(m.groups[2])
        }
        if let day, let monthName, let monthIndex = months.firstIndex(where: { $0.hasPrefix(String(monthName.prefix(3))) }) {
            let referenceYear = calendar.component(.year, from: reference)
            var components = DateComponents(year: year ?? referenceYear, month: monthIndex + 1, day: day)
            guard var date = calendar.date(from: components) else { return nil }
            // "Feb 3" said in December means next February.
            if year == nil, date < today.addingTimeInterval(-60 * 86_400) {
                components.year = referenceYear + 1
                date = calendar.date(from: components) ?? date
            }
            return date
        }

        for (index, name) in weekdays.enumerated() where lowered.contains(name) || lowered.contains(" \(name.prefix(3)) ") {
            let current = calendar.component(.weekday, from: today) // 1 = Sunday
            var delta = (index + 1) - current
            if delta <= 0 { delta += 7 }
            return plus(.day, delta)
        }

        if lowered.contains("end of the week") || lowered.contains("end of week") || lowered.contains("this week") {
            let current = calendar.component(.weekday, from: today)
            let delta = (6 - current + 7) % 7 // Friday
            return plus(.day, delta)
        }
        if lowered.contains("next week") { return plus(.day, 7) }
        if lowered.contains("end of the month") || lowered.contains("end of month") || lowered.contains("this month") {
            if let interval = calendar.dateInterval(of: .month, for: today) {
                return calendar.date(byAdding: .day, value: -1, to: interval.end)
            }
        }
        if lowered.contains("next month") { return plus(.month, 1) }
        return nil
    }
}

// MARK: - Extractive fallback

/// Rule-based summariser used when no language model is installed. It only ever quotes
/// sentences from the transcript, so it cannot invent content; quality is well below a
/// language model and the UI labels its output accordingly.
public enum ExtractiveSummarizer {
    static let decisionCues = [
        "we decided", "we've decided", "we have decided", "decided to", "we agreed", "agreed to", "agreed that",
        "the decision is", "let's go with", "we will go with", "we'll go with", "we are going with", "going to go with",
        "the plan is", "final decision",
        "we hebben besloten", "besloten om", "afgesproken", "nous avons décidé", "on a décidé", "décidé de",
        "ми вирішили", "вирішили", "домовилися", "قررنا", "اتفقنا",
    ]
    static let actionCues = [
        "i will ", "i'll ", "i am going to", "i'm going to", "we need to", "i need to", "you need to", "needs to",
        "action item", "to-do", "todo", "follow up", "can you ", "could you ", "please ", "make sure",
        "i'll take", "i can take", "assigned to", "responsible for", "by tomorrow", "by monday", "by tuesday",
        "by wednesday", "by thursday", "by friday", "by next week", "by the end of",
        "ik zal ", "ik ga ", "we moeten", "je vais ", "nous devons", "il faut ",
        "я зроблю", "я підготую", "нам потрібно", "треба ", "سأقوم", "يجب أن", "علينا أن",
    ]
    static let deadlineCues = ["by ", "due ", "deadline", "before ", "until ", "no later than"]

    public static func sentences(in segments: [TranscriptSegment]) -> [(text: String, start: Double)] {
        var result: [(String, Double)] = []
        var buffer = ""
        var bufferStart: Double?
        for segment in segments {
            for character in segment.text {
                if bufferStart == nil { bufferStart = segment.start }
                buffer.append(character)
                if ".!?؟…".contains(character) {
                    let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if sentence.count > 2 { result.append((sentence, bufferStart ?? segment.start)) }
                    buffer = ""
                    bufferStart = nil
                }
            }
            buffer.append(" ")
            // Whisper output is not always punctuated; do not let a sentence run on forever.
            if buffer.count > 280 {
                let sentence = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append((sentence, bufferStart ?? segment.start)) }
                buffer = ""
                bufferStart = nil
            }
        }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.count > 2 { result.append((rest, bufferStart ?? segments.last?.start ?? 0)) }
        return result
    }

    public static func summarize(segments: [TranscriptSegment], title: String, templateID: String) -> MeetingSummary {
        let sentences = sentences(in: segments)
        guard !sentences.isEmpty else {
            return MeetingSummary(title: title, overview: "", engine: "extractive", templateID: templateID)
        }

        var frequency: [String: Int] = [:]
        let tokenised = sentences.map { SearchQuery.keywords(in: $0.text).map(SearchQuery.stem) }
        for words in tokenised { for word in Set(words) { frequency[word, default: 0] += 1 } }

        let scored = tokenised.enumerated().map { index, words -> (index: Int, score: Double) in
            guard words.count >= 4 else { return (index, 0) }
            let total = words.reduce(0) { $0 + Double(frequency[$1] ?? 0) }
            return (index, total / Double(words.count).squareRoot())
        }
        let top = scored.sorted { $0.score > $1.score }.prefix(5).map(\.index).sorted()
        let overviewSentences = top.prefix(3).map { sentences[$0].text }
        let keyPoints = top.map { sentences[$0].text }

        func matching(_ cues: [String]) -> [String] {
            SummaryParser.dedupe(sentences.map(\.text).filter { sentence in
                let lowered = sentence.lowercased()
                return cues.contains { lowered.contains($0) }
            })
        }

        let decisions = Array(matching(decisionCues).prefix(8))
        let actionSentences = Array(matching(actionCues).filter { !decisions.contains($0) }.prefix(10))
        let actions = actionSentences.map { sentence -> ActionItemDraft in
            var due: String?
            let lowered = sentence.lowercased()
            if let match = QueryParser.firstMatch(
                #"\b(by|before|until|due) ((?:next |this |the end of (?:the )?)?[a-z]+(?: \d{1,2}(?:st|nd|rd|th)?)?)"#, in: lowered) {
                due = match.whole
            }
            return ActionItemDraft(task: sentence, owner: nil, due: due)
        }

        return MeetingSummary(
            title: title,
            overview: overviewSentences.joined(separator: " "),
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actions,
            deadlines: actions.compactMap { item in item.due.map { DeadlineNote(what: item.task, when: $0) } },
            facts: [],
            followUpQuestions: [],
            engine: "extractive",
            templateID: templateID)
    }
}

// MARK: - Summariser

public struct Summarizer: Sendable {
    public let llm: (any LanguageModelEngine)?

    public init(llm: (any LanguageModelEngine)?) {
        self.llm = llm
    }

    /// Renders a transcript as plain text, prefixing speaker names where the user assigned them.
    public static func render(segments: [TranscriptSegment], speakers: [Speaker] = []) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        var lines: [String] = []
        var lastSpeaker: String?
        for segment in segments {
            if let id = segment.speakerID, let name = names[id] {
                if id != lastSpeaker { lines.append("\(name): \(segment.text)") }
                else { lines.append(segment.text) }
                lastSpeaker = id
            } else {
                lines.append(segment.text)
                lastSpeaker = nil
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Splits text into parts no longer than `limit` characters, breaking on line ends.
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var parts: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = Substring(line)
            while line.count > limit {
                if !current.isEmpty { parts.append(current); current = "" }
                parts.append(String(line.prefix(limit)))
                line = line.dropFirst(limit)
            }
            if current.count + line.count + 1 > limit, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func notes(from summary: MeetingSummary) -> String {
        var lines: [String] = []
        if !summary.overview.isEmpty { lines.append("Summary: \(summary.overview)") }
        for point in summary.keyPoints { lines.append("Point: \(point)") }
        for decision in summary.decisions { lines.append("Decision: \(decision)") }
        for item in summary.actionItems {
            var line = "Action: \(item.task)"
            if let owner = item.owner { line += " (owner: \(owner))" }
            if let due = item.due { line += " (due: \(due))" }
            lines.append(line)
        }
        for fact in summary.facts { lines.append("Fact: \(fact)") }
        return lines.joined(separator: "\n")
    }

    /// Summarises a transcript. With a language model it produces structured notes (in
    /// several passes when the transcript exceeds the context window) and then removes
    /// items the transcript does not support. Without one it falls back to the
    /// extractive summariser.
    public func summarize(segments: [TranscriptSegment], speakers: [Speaker] = [], title: String,
                          template: SummaryTemplate,
                          progress: @escaping @Sendable (Double) -> Void = { _ in },
                          isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> MeetingSummary {
        guard let llm, !segments.isEmpty else {
            return ExtractiveSummarizer.summarize(segments: segments, title: title, templateID: template.id)
        }

        let transcript = Summarizer.render(segments: segments, speakers: speakers)
        let outputTokens = 700
        let overheadTokens = 380 + template.instructions.count / 3
        let inputTokens = llm.contextTokens - outputTokens - overheadTokens
        guard inputTokens > 300 else { throw EngineError.contextTooSmall }
        let limit = PromptBuilder.characterBudget(tokens: inputTokens, sample: transcript)
        let parts = Summarizer.split(transcript, limit: limit)
        let options = GenerationOptions(maxTokens: outputTokens, temperature: 0.1, grammar: PromptBuilder.summaryGrammar)
        let steps = Double(parts.count + (parts.count > 1 ? 1 : 0))

        var partials: [MeetingSummary] = []
        for (index, part) in parts.enumerated() {
            if isCancelled() { throw EngineError.cancelled }
            let messages = PromptBuilder.summaryMessages(
                transcript: part, title: title, template: template, part: index + 1, totalParts: parts.count)
            let output = try await llm.generate(messages: messages, options: options) { _ in !isCancelled() }
            if let parsed = SummaryParser.parse(output) { partials.append(parsed) }
            progress(Double(index + 1) / steps)
        }
        if isCancelled() { throw EngineError.cancelled }
        guard !partials.isEmpty else {
            // The model produced nothing usable; quoting the transcript beats showing nothing.
            return ExtractiveSummarizer.summarize(segments: segments, title: title, templateID: template.id)
        }

        var result: MeetingSummary
        if partials.count == 1 {
            result = partials[0]
        } else {
            // Lists are merged in code, not by the model, so the merge step cannot drop
            // or invent a decision or task. The model only rewrites the prose overview.
            result = MeetingSummary()
            result.decisions = SummaryParser.dedupe(partials.flatMap(\.decisions))
            result.facts = SummaryParser.dedupe(partials.flatMap(\.facts))
            result.keyPoints = SummaryParser.dedupe(partials.flatMap(\.keyPoints))
            result.followUpQuestions = Array(SummaryParser.dedupe(partials.flatMap(\.followUpQuestions)).prefix(6))
            var seenTasks = Set<String>()
            result.actionItems = partials.flatMap(\.actionItems).filter { seenTasks.insert($0.task.lowercased()).inserted }
            var seenDeadlines = Set<String>()
            result.deadlines = partials.flatMap(\.deadlines).filter { seenDeadlines.insert($0.what.lowercased()).inserted }

            var notes = partials.map(Summarizer.notes(from:)).joined(separator: "\n")
            if notes.count > limit { notes = String(notes.prefix(limit)) }
            let merged = try await llm.generate(
                messages: PromptBuilder.mergeMessages(notes: notes, title: title, template: template),
                options: options) { _ in !isCancelled() }
            if let parsed = SummaryParser.parse(merged) {
                result.title = parsed.title
                result.overview = parsed.overview
                if !parsed.keyPoints.isEmpty { result.keyPoints = Array(parsed.keyPoints.prefix(10)) }
            } else {
                result.title = partials[0].title
                result.overview = partials.map(\.overview).filter { !$0.isEmpty }.joined(separator: " ")
            }
            progress(1)
        }

        result = Grounding.filter(result, transcript: transcript)
        if result.title.isEmpty { result.title = title }
        result.engine = "llm:\(llm.modelID)"
        result.templateID = template.id
        result.createdAt = Date()
        return result
    }
}

// MARK: - Tasks from summaries

public enum TaskExtractor {
    /// Converts a summary's action items into tasks, resolving due dates relative to the
    /// recording date and linking each task to the transcript position it came from.
    public static func tasks(from summary: MeetingSummary, recording: Recording, segments: [TranscriptSegment],
                             calendar: Calendar = .current) -> [TaskItem] {
        summary.actionItems.map { item in
            TaskItem(
                recordingID: recording.id,
                title: item.task,
                owner: item.owner,
                dueAt: item.due.flatMap { DueDateParser.parse($0, relativeTo: recording.createdAt, calendar: calendar) },
                dueText: item.due,
                createdAt: recording.createdAt,
                sourceStart: bestSegment(for: item.task, in: segments)?.start,
                origin: .extracted)
        }
    }

    static func bestSegment(for text: String, in segments: [TranscriptSegment]) -> TranscriptSegment? {
        let words = Set(Grounding.contentWords(text))
        guard !words.isEmpty else { return nil }
        var best: (segment: TranscriptSegment, score: Int)?
        for segment in segments {
            let score = Set(Grounding.contentWords(segment.text)).intersection(words).count
            if score > (best?.score ?? 0) { best = (segment, score) }
        }
        return best?.segment
    }
}
