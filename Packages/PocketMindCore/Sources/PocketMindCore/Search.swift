import Foundation

/// Groups consecutive transcript segments into overlapping, timestamped chunks that are
/// small enough to hand to a local language model as retrieval context.
public enum Chunker {
    public struct Draft: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public static func chunks(from segments: [TranscriptSegment], targetCharacters: Int = 700,
                              overlapSegments: Int = 1) -> [Draft] {
        var result: [Draft] = []
        var current: [TranscriptSegment] = []
        var length = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            result.append(Draft(start: first.start, end: last.end,
                                text: current.map(\.text).joined(separator: " ")))
        }

        for segment in segments {
            if length + segment.text.count > targetCharacters, !current.isEmpty {
                flush()
                current = Array(current.suffix(max(0, overlapSegments)))
                length = current.reduce(0) { $0 + $1.text.count + 1 }
                // An overlap that is itself over budget would grow chunks without bound.
                if length > targetCharacters / 2 { current = []; length = 0 }
            }
            current.append(segment)
            length += segment.text.count + 1
        }
        // The trailing group is only worth storing if it holds something new.
        if let last = current.last, result.last?.end != last.end || result.isEmpty {
            flush()
        }
        return result
    }
}

public enum SearchQuery {
    /// Words that carry no retrieval signal. English first, with the most common function
    /// words of the other supported languages.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "of", "to", "in", "on", "at", "for", "with", "by", "from",
        "about", "as", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done",
        "have", "has", "had", "i", "me", "my", "mine", "we", "us", "our", "you", "your", "he", "she", "it",
        "they", "them", "their", "this", "that", "these", "those", "what", "which", "who", "whom", "when",
        "where", "why", "how", "any", "all", "some", "there", "here", "so", "than", "then", "too", "very",
        "can", "could", "should", "would", "will", "shall", "may", "might", "must", "not", "no", "yes",
        "tell", "show", "find", "give", "list", "please", "into", "over", "up", "out", "just", "also",
        "said", "say", "says", "talk", "talked", "discuss", "discussed", "discussion", "mention", "mentioned",
        "conversation", "conversations", "recording", "recordings", "meeting", "meetings", "summarize",
        "summarise", "summary", "decide", "decided", "decision", "decisions",
        // Dutch
        "de", "het", "een", "en", "van", "ik", "je", "dat", "die", "niet", "wat", "over", "hebben", "wij",
        // French
        "le", "la", "les", "un", "une", "des", "et", "du", "que", "qui", "je", "nous", "vous", "est", "sur", "dans",
        // Ukrainian
        "і", "й", "та", "в", "у", "на", "що", "це", "як", "я", "ми", "ви", "про", "за", "до", "не",
        // Arabic
        "في", "من", "على", "عن", "ما", "ماذا", "هذا", "هذه", "أن", "إلى", "هل", "مع", "و",
    ]

    /// Lower-cased alphanumeric words of at least two characters.
    public static func keywords(in text: String, dropStopwords: Bool = true) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        let parts = text.lowercased().split { !($0.isLetter || $0.isNumber) }
        for part in parts {
            let word = String(part)
            guard word.count >= 2 else { continue }
            if dropStopwords, stopwords.contains(word) { continue }
            if seen.insert(word).inserted { words.append(word) }
        }
        return words
    }

    /// Very light English suffix stripping so "decided" also finds "decide" and
    /// "deadlines" finds "deadline". Non-ASCII words are returned unchanged.
    static func stem(_ word: String) -> String {
        guard word.allSatisfy({ $0.isASCII }), word.count >= 6 else { return word }
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) {
            let stemmed = String(word.dropLast(suffix.count))
            if stemmed.count >= 4 { return stemmed }
        }
        return word
    }

    /// Builds an FTS5 MATCH expression of quoted prefix terms. Returns nil when there is
    /// nothing to search for. Quoting keeps user input from being read as FTS syntax.
    public static func ftsExpression(for keywords: [String], matchAll: Bool = false) -> String? {
        let terms = keywords.compactMap { keyword -> String? in
            let cleaned = String(keyword.filter { $0.isLetter || $0.isNumber })
            guard !cleaned.isEmpty else { return nil }
            return "\"\(stem(cleaned))\"*"
        }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: matchAll ? " AND " : " OR ")
    }
}

public enum QueryIntent: String, Sendable {
    case general, tasks, deadlines, overview
}

public struct ParsedQuery: Sendable {
    public var original: String
    public var keywords: [String]
    public var dateRange: DateInterval?
    public var dateLabel: String?
    public var intent: QueryIntent
}

/// Turns a natural-language question into something the retriever can execute:
/// a date window, an intent and a set of search keywords.
public enum QueryParser {
    public static func parse(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedQuery {
        var text = " " + question.lowercased() + " "
        var range: DateInterval?
        var label: String?

        let startOfToday = calendar.startOfDay(for: now)
        func days(_ n: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }

        func take(_ phrases: [String]) -> Bool {
            for phrase in phrases where text.contains(phrase) {
                text = text.replacingOccurrences(of: phrase, with: " ")
                return true
            }
            return false
        }

        if let match = firstMatch(#"(?:last|past) (\d{1,3}) days?"#, in: text), let n = Int(match.groups[0]) {
            range = DateInterval(start: days(-n, from: startOfToday), end: days(1, from: startOfToday))
            label = "the last \(n) days"
            text = text.replacingOccurrences(of: match.whole, with: " ")
        } else if take(["day before yesterday"]) {
            range = DateInterval(start: days(-2, from: startOfToday), end: days(-1, from: startOfToday))
            label = "the day before yesterday"
        } else if take([" yesterday"]) {
            range = DateInterval(start: days(-1, from: startOfToday), end: startOfToday)
            label = "yesterday"
        } else if take([" today", " this morning", " this afternoon", " this evening"]) {
            range = DateInterval(start: startOfToday, end: days(1, from: startOfToday))
            label = "today"
        } else if take([" last week", " previous week"]) {
            if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
                range = DateInterval(start: days(-7, from: thisWeek.start), end: thisWeek.start)
                label = "last week"
            }
        } else if take([" this week"]) {
            range = calendar.dateInterval(of: .weekOfYear, for: now)
            label = "this week"
        } else if take([" past week"]) {
            range = DateInterval(start: days(-7, from: startOfToday), end: days(1, from: startOfToday))
            label = "the past week"
        } else if take([" last month", " previous month"]) {
            if let thisMonth = calendar.dateInterval(of: .month, for: now),
               let start = calendar.date(byAdding: .month, value: -1, to: thisMonth.start) {
                range = DateInterval(start: start, end: thisMonth.start)
                label = "last month"
            }
        } else if take([" this month"]) {
            range = calendar.dateInterval(of: .month, for: now)
            label = "this month"
        } else if take([" this year"]) {
            range = calendar.dateInterval(of: .year, for: now)
            label = "this year"
        }

        let intent: QueryIntent
        if containsAny(text, ["deadline", "due date", "due by", "due this", " due "]) {
            intent = .deadlines
        } else if containsAny(text, ["task", "to-do", "todo", "to do", "action item", "promise", "commit", "follow up", "follow-up", "supposed to"]) {
            intent = .tasks
        } else if containsAny(text, ["summarize", "summarise", "summary", "recap", "overview", "what did i discuss",
                                     "what did we discuss", "what did i talk", "what did we talk", "what happened"]) {
            intent = .overview
        } else {
            intent = .general
        }

        var keywords = SearchQuery.keywords(in: text)
        let intentWords: Set<String> = ["tasks", "task", "todo", "deadline", "deadlines", "due", "promise", "promised",
                                        "complete", "action", "items", "item", "recap", "overview", "week", "month",
                                        "happened", "commit", "committed", "follow"]
        if intent != .general { keywords.removeAll { intentWords.contains($0) } }

        return ParsedQuery(original: question, keywords: keywords, dateRange: range, dateLabel: label, intent: intent)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    struct Match { var whole: String; var groups: [String] }

    static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var groups: [String] = []
        if result.numberOfRanges > 1 {
            for index in 1..<result.numberOfRanges {
                let r = result.range(at: index)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
        }
        return Match(whole: ns.substring(with: result.range), groups: groups)
    }
}
