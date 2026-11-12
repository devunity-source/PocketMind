import Foundation
import PocketMindCore
import whisper

/// On-device speech recognition with whisper.cpp. One instance owns one loaded model.
/// Calls are serialised on a private queue because a whisper context is not thread safe.
public final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {
    public let modelID: String
    public let usesGPU: Bool
    private let context: OpaquePointer
    private let queue = DispatchQueue(label: "app.pocketmind.whisper", qos: .userInitiated)

    private final class Callbacks {
        let progress: @Sendable (Double) -> Void
        let isCancelled: @Sendable () -> Bool
        init(progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool) {
            self.progress = progress
            self.isCancelled = isCancelled
        }
    }

    private static let silenceLogging: Void = {
        // whisper.cpp logs model details to stderr. Nothing it prints contains transcript
        // text, but a release build has no reason to log at all.
        whisper_log_set({ _, _, _ in }, nil)
    }()

    /// - Parameter useGPU: Metal acceleration. Must be false when running in the
    ///   background, where iOS does not allow GPU work, and on the simulator.
    public init(modelPath: String, modelID: String, useGPU: Bool) throws {
        _ = WhisperEngine.silenceLogging
        var parameters = whisper_context_default_params()
        #if targetEnvironment(simulator)
        parameters.use_gpu = false
        #else
        parameters.use_gpu = useGPU
        #endif
        guard let context = whisper_init_from_file_with_params(modelPath, parameters) else {
            throw EngineError.modelLoadFailed("whisper.cpp could not read the model file.")
        }
        self.context = context
        self.modelID = modelID
        self.usesGPU = parameters.use_gpu
    }

    deinit {
        whisper_free(context)
    }

    public var isMultilingual: Bool { whisper_is_multilingual(context) != 0 }

    public func transcribe(samples: [Float], language: String?,
                           progress: @escaping @Sendable (Double) -> Void,
                           isCancelled: @escaping @Sendable () -> Bool) async throws -> TranscriptionOutput {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.run(samples: samples, language: language, progress: progress, isCancelled: isCancelled)
                })
            }
        }
    }

    private func run(samples: [Float], language: String?,
                     progress: @escaping @Sendable (Double) -> Void,
                     isCancelled: @escaping @Sendable () -> Bool) throws -> TranscriptionOutput {
        if isCancelled() { throw EngineError.cancelled }

        // whisper.cpp rejects input shorter than one second; pad with silence.
        var audio = samples
        let minimum = 16_000 + 1_600
        if audio.count < minimum { audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count)) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // Leave two cores for the UI and audio; more threads than performance cores slows whisper down.
        parameters.n_threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        parameters.translate = false
        parameters.no_context = true          // avoids runaway repetition across windows
        parameters.no_timestamps = false
        parameters.single_segment = false
        parameters.print_special = false
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.suppress_blank = true
        parameters.detect_language = false    // true would stop after detection without transcribing

        let callbacks = Callbacks(progress: progress, isCancelled: isCancelled)
        let unmanaged = Unmanaged.passRetained(callbacks)
        defer { unmanaged.release() }
        let userData = unmanaged.toOpaque()

        parameters.progress_callback = { _, _, percent, userData in
            guard let userData else { return }
            Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().progress(Double(percent) / 100)
        }
        parameters.progress_callback_user_data = userData
        parameters.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().isCancelled()
        }
        parameters.abort_callback_user_data = userData

        // nil / "auto" lets Whisper detect the language from the first 30 seconds.
        let languageCode = (language?.isEmpty == false) ? language! : "auto"
        let status: Int32 = languageCode.withCString { languagePointer in
            parameters.language = languagePointer
            return audio.withUnsafeBufferPointer { buffer in
                whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
            }
        }

        if isCancelled() { throw EngineError.cancelled }
        guard status == 0 else {
            throw EngineError.inferenceFailed("whisper.cpp returned status \(status).")
        }

        var segments: [RawSegment] = []
        let count = whisper_full_n_segments(context)
        for index in 0..<count {
            guard let pointer = whisper_full_get_segment_text(context, index) else { continue }
            let text = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !WhisperEngine.isNonSpeechMarker(text) else { continue }
            // Timestamps are in units of 10 ms.
            let start = Double(whisper_full_get_segment_t0(context, index)) / 100
            let end = Double(whisper_full_get_segment_t1(context, index)) / 100
            segments.append(RawSegment(start: start, end: max(end, start), text: text))
        }

        var detected: String? = language
        let languageID = whisper_full_lang_id(context)
        if languageID >= 0, let pointer = whisper_lang_str(languageID) {
            detected = String(cString: pointer)
        }
        progress(1)
        return TranscriptionOutput(segments: segments, language: detected)
    }

    /// Whisper marks silence and noise with bracketed tokens such as "[BLANK_AUDIO]" or
    /// "(music)". They are not speech and are left out of the transcript.
    static func isNonSpeechMarker(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return true }
        return (first == "[" && last == "]") || (first == "(" && last == ")") || (first == "*" && last == "*")
    }
}
