import Foundation

// Protocols that separate the app's logic from the native inference libraries.
// The real implementations (whisper.cpp, llama.cpp) live in the LocalAI package;
// tests use in-memory fakes.

public struct TranscriptionOutput: Sendable {
    public var segments: [RawSegment]
    /// ISO 639-1 code detected or used, e.g. "en", "ar", "uk", "nl", "fr".
    public var language: String?

    public init(segments: [RawSegment], language: String?) {
        self.segments = segments
        self.language = language
    }
}

public protocol TranscriptionEngine: Sendable {
    /// - Parameters:
    ///   - samples: 16 kHz mono PCM in the range -1...1.
    ///   - language: ISO 639-1 code, or nil to auto-detect.
    ///   - progress: called with 0...1 for this buffer.
    ///   - isCancelled: polled by the engine; returning true aborts the run.
    func transcribe(samples: [Float], language: String?,
                    progress: @escaping @Sendable (Double) -> Void,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> TranscriptionOutput
}

public struct ChatMessage: Hashable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Double
    /// Optional GBNF grammar constraining the output (used for structured JSON).
    public var grammar: String?

    public init(maxTokens: Int = 512, temperature: Double = 0.2, grammar: String? = nil) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.grammar = grammar
    }
}

public protocol LanguageModelEngine: Sendable {
    /// Identifier of the loaded model, recorded with every summary it produces.
    var modelID: String { get }
    /// Size of the context window in tokens.
    var contextTokens: Int { get }
    /// - Parameter onToken: receives each generated piece; return false to stop early.
    func generate(messages: [ChatMessage], options: GenerationOptions,
                  onToken: @escaping @Sendable (String) -> Bool) async throws -> String
}

public enum EngineError: Error, LocalizedError, Sendable {
    case modelNotInstalled
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case cancelled
    case contextTooSmall

    public var errorDescription: String? {
        switch self {
        case .modelNotInstalled: "No model is installed. Install one in Settings → AI Models."
        case .modelLoadFailed(let detail): "The model could not be loaded. \(detail)"
        case .inferenceFailed(let detail): "On-device processing failed. \(detail)"
        case .cancelled: "Cancelled."
        case .contextTooSmall: "The text is too long for this model's context window."
        }
    }
}

/// Picks split points for long recordings so that audio can be transcribed window by
/// window without holding hours of PCM in memory or cutting through the middle of a word.
public enum AudioWindowing {
    /// Returns the sample index at which to cut `samples`, searching the final
    /// `searchSeconds` for the quietest stretch. Everything before the returned index is
    /// transcribed now; the remainder is carried into the next window.
    public static func splitIndex(samples: [Float], sampleRate: Int = 16_000,
                                  searchSeconds: Double = 20, frameSeconds: Double = 0.4) -> Int {
        let frame = max(1, Int(Double(sampleRate) * frameSeconds))
        let searchLength = min(samples.count, Int(Double(sampleRate) * searchSeconds))
        guard searchLength >= frame * 2 else { return samples.count }

        let searchStart = samples.count - searchLength
        var bestStart = samples.count - frame
        var bestEnergy = Float.greatestFiniteMagnitude
        var position = searchStart
        while position + frame <= samples.count {
            var energy: Float = 0
            for index in position..<(position + frame) {
                energy += samples[index] * samples[index]
            }
            // "<=" prefers the latest equally quiet frame, keeping windows as long as possible.
            if energy <= bestEnergy {
                bestEnergy = energy
                bestStart = position
            }
            position += frame / 2
        }
        return bestStart + frame / 2
    }
}

/// Converts measured benchmark rates into honest processing-time estimates.
public enum ProcessingEstimator {
    /// - Parameter realTimeFactor: measured processing seconds per second of audio.
    public static func transcriptionSeconds(audioDuration: Double, realTimeFactor: Double?) -> Double? {
        guard let realTimeFactor, realTimeFactor > 0 else { return nil }
        return audioDuration * realTimeFactor
    }

    public static func describe(seconds: Double?) -> String {
        guard let seconds else { return "Not measured yet — run a benchmark in Settings → AI Models" }
        if seconds < 60 { return "about \(max(1, Int(seconds.rounded()))) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "about \(Int(minutes.rounded())) min" }
        return String(format: "about %.1f h", minutes / 60)
    }
}
