import Foundation
import PocketMindCore

#if !canImport(llama)

/// Stand-in used when the package is built without llama.cpp (iOS Simulator builds, see
/// Package.swift). It has the same interface and always reports the model as unavailable,
/// so the app falls back to its no-language-model behaviour.
public final class LlamaEngine: LanguageModelEngine, @unchecked Sendable {
    public let modelID: String
    public let contextTokens: Int
    public let usesGPU = false

    public init(modelPath: String, modelID: String, contextTokens: Int = 4096, useGPU: Bool) throws {
        throw EngineError.modelLoadFailed("Language models are not available in iOS Simulator builds. Run on an iPhone.")
    }

    public func generate(messages: [ChatMessage], options: GenerationOptions,
                         onToken: @escaping @Sendable (String) -> Bool) async throws -> String {
        throw EngineError.modelNotInstalled
    }
}

#else

import llama

/// On-device text generation with llama.cpp. One instance owns one loaded GGUF model and
/// one context; calls are serialised on a private queue.
public final class LlamaEngine: LanguageModelEngine, @unchecked Sendable {
    public let modelID: String
    public let contextTokens: Int
    public let usesGPU: Bool

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let batchSize: Int32 = 512
    private let queue = DispatchQueue(label: "app.pocketmind.llama", qos: .userInitiated)

    private static let backend: Void = {
        // Model metadata only; prompts and outputs are never logged by llama.cpp, but a
        // release build has no reason to log at all.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// - Parameters:
    ///   - contextTokens: context window to allocate. Memory use grows with it, so the
    ///     app asks for 4096 rather than the model's maximum.
    ///   - useGPU: Metal offload. Must be false in the background and on the simulator.
    public init(modelPath: String, modelID: String, contextTokens: Int = 4096, useGPU: Bool) throws {
        _ = LlamaEngine.backend

        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        let gpu = false
        #else
        let gpu = useGPU
        #endif
        modelParameters.n_gpu_layers = gpu ? 999 : 0
        guard let model = llama_model_load_from_file(modelPath, modelParameters) else {
            throw EngineError.modelLoadFailed("llama.cpp could not read the model file.")
        }

        var contextParameters = llama_context_default_params()
        let trained = Int(llama_model_n_ctx_train(model))
        let requested = trained > 0 ? min(contextTokens, trained) : contextTokens
        contextParameters.n_ctx = UInt32(requested)
        contextParameters.n_batch = UInt32(batchSize)
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParameters.n_threads = threads
        contextParameters.n_threads_batch = threads
        contextParameters.no_perf = true

        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw EngineError.modelLoadFailed("Not enough memory to create a \(requested)-token context.")
        }
        guard let vocabulary = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw EngineError.modelLoadFailed("The model has no vocabulary.")
        }

        self.model = model
        self.context = context
        self.vocabulary = vocabulary
        self.modelID = modelID
        self.contextTokens = Int(llama_n_ctx(context))
        self.usesGPU = gpu
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    public func generate(messages: [ChatMessage], options: GenerationOptions,
                         onToken: @escaping @Sendable (String) -> Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.run(messages: messages, options: options, onToken: onToken)
                })
            }
        }
    }

    // MARK: - Prompt

    /// Formats the conversation with the chat template stored in the model file, falling
    /// back to ChatML when the model carries a template llama.cpp does not recognise.
    private func prompt(for messages: [ChatMessage]) -> String {
        let roles = messages.map { strdup($0.role.rawValue) }
        let contents = messages.map { strdup($0.content) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        let chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }
        let template = llama_model_chat_template(model, nil)

        if template != nil {
            let estimated = messages.reduce(256) { $0 + $1.content.utf8.count * 2 + 64 }
            var buffer = [CChar](repeating: 0, count: estimated)
            var written = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
            if written > Int32(buffer.count) {
                buffer = [CChar](repeating: 0, count: Int(written) + 1)
                written = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
            }
            if written > 0 {
                let bytes = buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }

        var text = ""
        for message in messages {
            text += "<|im_start|>\(message.role.rawValue)\n\(message.content)<|im_end|>\n"
        }
        return text + "<|im_start|>assistant\n"
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let byteCount = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(byteCount) + 16)
        var count = llama_tokenize(vocabulary, text, byteCount, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocabulary, text, byteCount, &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw EngineError.inferenceFailed("The prompt could not be tokenised.") }
        return Array(tokens.prefix(Int(count)))
    }

    // MARK: - Generation

    private func run(messages: [ChatMessage], options: GenerationOptions,
                     onToken: @escaping @Sendable (String) -> Bool) throws -> String {
        var tokens = try tokenize(prompt(for: messages))
        let available = contextTokens - tokens.count
        guard available >= 32 else { throw EngineError.contextTooSmall }
        let maxNewTokens = min(options.maxTokens, available - 4)

        // Every request starts from an empty context: nothing from an earlier recording
        // or question can leak into this answer.
        llama_memory_clear(llama_get_memory(context), true)

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw EngineError.inferenceFailed("Could not create the sampler.")
        }
        defer { llama_sampler_free(sampler) }
        if let grammar = options.grammar, let constraint = llama_sampler_init_grammar(vocabulary, grammar, "root") {
            llama_sampler_chain_add(sampler, constraint)
        }
        if options.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(options.temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32(LLAMA_DEFAULT_SEED)))
        }

        // Evaluate the prompt in batches.
        var offset = 0
        while offset < tokens.count {
            if !onToken("") { throw EngineError.cancelled }
            let count = min(Int(batchSize), tokens.count - offset)
            let status: Int32 = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw EngineError.inferenceFailed("llama_decode returned \(status) on the prompt.") }
            offset += count
        }

        var output = ""
        var pending: [UInt8] = []   // bytes of a UTF-8 character split across tokens
        var piece = [CChar](repeating: 0, count: 256)

        for _ in 0..<maxNewTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }

            let length = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
            if length > 0 {
                pending.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
                if let text = String(bytes: pending, encoding: .utf8) {
                    pending.removeAll(keepingCapacity: true)
                    output += text
                    if !onToken(text) { throw EngineError.cancelled }
                } else if pending.count > 8 {
                    // Not a split character after all: emit it lossily rather than stall.
                    let text = String(decoding: pending, as: UTF8.self)
                    pending.removeAll(keepingCapacity: true)
                    output += text
                    if !onToken(text) { throw EngineError.cancelled }
                }
            }

            // The batch only borrows the token pointer, so it must stay valid for the
            // whole llama_decode call, not just for llama_batch_get_one.
            let status = withUnsafeMutablePointer(to: &token) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1))
            }
            guard status == 0 else { throw EngineError.inferenceFailed("llama_decode returned \(status).") }
        }
        if !pending.isEmpty { output += String(decoding: pending, as: UTF8.self) }
        return output
    }
}

#endif