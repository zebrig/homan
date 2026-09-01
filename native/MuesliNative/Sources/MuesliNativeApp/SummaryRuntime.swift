import Foundation
import LlamaSwift

/// In-process GGUF runtime over `mattt/llama.swift` (llama.cpp b10280, Metal).
///
/// Replaces the LLM.swift `bot` inside `GemmaSummaryBackend` for on-device summarization.
/// Config matches the A2 recon (spec 005 Phase 0): full Metal offload, `n_batch=2048`
/// chunked prefill, `n_ubatch=2048`, and flash attention on. Project Niko renders
/// Gemma with the exact embedded Jinja template; the legacy Qwen cleanup path keeps
/// its previous llama.cpp ChatML formatting explicitly.
///
/// Not an actor: it is serialized externally by `GemmaSummaryBackend` (actor + InferenceGate)
/// and additionally guards its own state with an `NSLock`.
final class SummaryRuntime {
    private enum BackendLifecycle {
        private static let lock = NSLock()
        private static var referenceCount = 0

        static func acquire() {
            lock.lock(); defer { lock.unlock() }
            if referenceCount == 0 { llama_backend_init() }
            referenceCount += 1
        }

        static func release() {
            lock.lock(); defer { lock.unlock() }
            guard referenceCount > 0 else { return }
            referenceCount -= 1
            if referenceCount == 0 { llama_backend_free() }
        }
    }

    enum PromptFamily: String {
        case gemmaJinja
        case legacyChatML
    }

    enum PromptMode {
        case gemma(enableThinking: Bool)
        case legacyChatML
    }

    enum RuntimeError: LocalizedError {
        case modelMissing(URL)
        case modelLoadFailed(URL)
        case contextCreationFailed
        case samplerCreationFailed
        case missingVocabulary
        case promptFamilyMismatch
        case legacyTemplateFailed
        case tokenizationFailed
        case decodeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case let .modelMissing(url): return "GGUF model not found at \(url.path)."
            case let .modelLoadFailed(url): return "Failed to load GGUF model at \(url.path)."
            case .contextCreationFailed: return "Failed to create the llama.cpp context."
            case .samplerCreationFailed: return "Failed to create the llama.cpp sampler."
            case .missingVocabulary: return "The GGUF model has no usable vocabulary."
            case .promptFamilyMismatch: return "The loaded model and requested prompt renderer do not match."
            case .legacyTemplateFailed: return "The legacy Qwen ChatML prompt could not be rendered."
            case .tokenizationFailed: return "The rendered model prompt could not be tokenized."
            case let .decodeFailed(code): return "llama.cpp decoding failed with code \(code)."
            }
        }
    }

    private let lock = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    // llama.swift 2.10280+ exposes llama_sampler as a concrete struct (b10276 was opaque).
    private var samplerChain: UnsafeMutablePointer<llama_sampler>?
    private var loadedURL: URL?
    private var loadedSamplerKey: String?
    private var loadedPromptFamily: PromptFamily?
    private var gemmaTemplate: GemmaChatTemplate?
    private var holdsBackendLease = false

    static let defaultContextTokens: Int32 = 32_768
    /// llama-cli's default; n_batch=512 was measurably slower on the M4 (7.9 vs 11.3 t/s QAT).
    static let batchSize = 2048

    // MARK: - Loading

    /// Load a GGUF model into Metal and prepare a sampler chain. Reloads only when
    /// the model, sampler, or prompt family changes and throws a diagnostic error on failure.
    func load(
        modelURL: URL,
        contextTokens: Int32,
        topK: Int32,
        topP: Float,
        temp: Float,
        seed: UInt32,
        promptFamily: PromptFamily
    ) throws {
        lock.lock(); defer { lock.unlock() }
        let samplerKey = "\(contextTokens)|\(topK)|\(topP)|\(temp)|\(promptFamily.rawValue)"
        if let loadedURL,
           loadedURL == modelURL,
           loadedSamplerKey == samplerKey,
           loadedPromptFamily == promptFamily,
           model != nil {
            return
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RuntimeError.modelMissing(modelURL)
        }

        // Tear down the previous model before (re)initializing the process backend.
        // The old order initialized and immediately freed the backend on a cold load.
        shutdownLocked()

        if !holdsBackendLease {
            BackendLifecycle.acquire()
            holdsBackendLease = true
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else {
            throw RuntimeError.modelLoadFailed(modelURL)
        }

        let compiledGemmaTemplate: GemmaChatTemplate?
        switch promptFamily {
        case .gemmaJinja:
            guard let templatePointer = llama_model_chat_template(m, nil) else {
                llama_model_free(m)
                throw GemmaChatTemplateError.missing
            }
            do {
                compiledGemmaTemplate = try GemmaChatTemplate(source: String(cString: templatePointer))
                if let compiledGemmaTemplate {
                    fputs(
                        "[summary] Project Niko loaded Gemma Jinja template sha256=\(compiledGemmaTemplate.sourceSHA256)\n",
                        stderr
                    )
                }
            } catch {
                llama_model_free(m)
                throw error
            }
        case .legacyChatML:
            compiledGemmaTemplate = nil
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextTokens)
        cparams.n_batch = UInt32(Self.batchSize)
        cparams.n_ubatch = UInt32(Self.batchSize)
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        cparams.n_threads = Int32(ProcessInfo.processInfo.processorCount)
        cparams.n_threads_batch = Int32(ProcessInfo.processInfo.processorCount)
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw RuntimeError.contextCreationFailed
        }

        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        guard let chain = llama_sampler_chain_init(sparams) else {
            llama_free(c)
            llama_model_free(m)
            throw RuntimeError.samplerCreationFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temp))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))

        guard let modelVocabulary = llama_model_get_vocab(m) else {
            llama_sampler_free(chain)
            llama_free(c)
            llama_model_free(m)
            throw RuntimeError.missingVocabulary
        }

        model = m
        context = c
        vocab = modelVocabulary
        samplerChain = chain
        gemmaTemplate = compiledGemmaTemplate
        loadedURL = modelURL
        loadedSamplerKey = samplerKey
        loadedPromptFamily = promptFamily
    }

    // MARK: - Generation

    /// Generate one assistant turn for a system+user prompt. Returns raw text; the caller
    /// strips thinking/markers via `GemmaSummaryOutputCleaner`. Clears the KV cache and sampler
    /// state per call so the context can be reused across independent turns.
    func respond(
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int32,
        promptMode: PromptMode
    ) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let context, let vocab, let samplerChain else {
            throw RuntimeError.contextCreationFailed
        }

        // b10276 renamed kv_cache_clear → llama_memory_clear(llama_get_memory(ctx), data:)
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(samplerChain)

        let rendered: String
        let addSpecial: Bool
        switch promptMode {
        case let .gemma(enableThinking):
            guard loadedPromptFamily == .gemmaJinja, let gemmaTemplate else {
                throw RuntimeError.promptFamilyMismatch
            }
            rendered = try gemmaTemplate.render(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                enableThinking: enableThinking,
                bosToken: tokenText(llama_vocab_bos(vocab), vocab: vocab, fallback: "<bos>"),
                eosToken: tokenText(llama_vocab_eos(vocab), vocab: vocab, fallback: "<eos>")
            )
            // The embedded template emits its own BOS.
            addSpecial = false
        case .legacyChatML:
            guard loadedPromptFamily == .legacyChatML else {
                throw RuntimeError.promptFamilyMismatch
            }
            rendered = try renderLegacyChatML(systemPrompt: systemPrompt, userPrompt: userPrompt)
            addSpecial = true
        }

        let promptTokens = try tokenize(rendered, vocab: vocab, addSpecial: addSpecial)

        var code: Int32 = 0
        var pos = 0
        while pos < promptTokens.count {
            let n = min(Self.batchSize, promptTokens.count - pos)
            var slice = Array(promptTokens[pos..<(pos + n)])
            let batch = llama_batch_get_one(&slice, Int32(n))
            code = llama_decode(context, batch)
            if code != 0 { throw RuntimeError.decodeFailed(code) }
            pos += n
        }

        var outTokens: [llama_token] = []
        outTokens.reserveCapacity(Int(maxOutputTokens))
        var token = llama_sampler_sample(samplerChain, context, -1)
        while !llama_vocab_is_eog(vocab, token) && outTokens.count < Int(maxOutputTokens) {
            outTokens.append(token)
            var one = token
            let genBatch = llama_batch_get_one(&one, 1)
            code = llama_decode(context, genBatch)
            if code != 0 { throw RuntimeError.decodeFailed(code) }
            token = llama_sampler_sample(samplerChain, context, -1)
        }

        var text = ""
        text.reserveCapacity(outTokens.count * 4)
        for t in outTokens {
            text += tokenPiece(t, vocab: vocab)
        }
        return text
    }

    private func renderLegacyChatML(systemPrompt: String, userPrompt: String) throws -> String {
        let sysRole = strdup("system")!
        let userRole = strdup("user")!
        let sysC = strdup(systemPrompt)!
        let userC = strdup(userPrompt)!
        defer { free(sysRole); free(userRole); free(sysC); free(userC) }

        var chat: [llama_chat_message] = []
        var systemMessage = llama_chat_message()
        systemMessage.role = UnsafePointer(sysRole)
        systemMessage.content = UnsafePointer(sysC)
        chat.append(systemMessage)
        var userMessage = llama_chat_message()
        userMessage.role = UnsafePointer(userRole)
        userMessage.content = UnsafePointer(userC)
        chat.append(userMessage)

        return try chat.withUnsafeBufferPointer { buffer in
            var output = [CChar](repeating: 0, count: 64 * 1024)
            var count = llama_chat_apply_template(
                nil,
                buffer.baseAddress,
                buffer.count,
                true,
                &output,
                Int32(output.count)
            )
            if count > output.count {
                output = [CChar](repeating: 0, count: Int(count) + 1)
                count = llama_chat_apply_template(
                    nil,
                    buffer.baseAddress,
                    buffer.count,
                    true,
                    &output,
                    Int32(output.count)
                )
            }
            guard count >= 0, count <= output.count else {
                throw RuntimeError.legacyTemplateFailed
            }
            return String(decoding: output.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
    }

    private func tokenize(
        _ text: String,
        vocab: OpaquePointer,
        addSpecial: Bool
    ) throws -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: max(text.utf8.count + 64, 64))
        var count = llama_tokenize(
            vocab,
            text,
            Int32(text.utf8.count),
            &tokens,
            Int32(tokens.count),
            addSpecial,
            true
        )
        if count < 0, count != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(
                vocab,
                text,
                Int32(text.utf8.count),
                &tokens,
                Int32(tokens.count),
                addSpecial,
                true
            )
        }
        guard count > 0 else { throw RuntimeError.tokenizationFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenPiece(_ token: llama_token, vocab: OpaquePointer) -> String {
        var bytes = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocab, token, &bytes, Int32(bytes.count), 0, false)
        if count < 0, count != Int32.min {
            bytes = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocab, token, &bytes, Int32(bytes.count), 0, false)
        }
        guard count > 0 else { return "" }
        return String(decoding: bytes.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func tokenText(_ token: llama_token, vocab: OpaquePointer, fallback: String) -> String {
        guard token >= 0, let pointer = llama_vocab_get_text(vocab, token) else { return fallback }
        let value = String(cString: pointer)
        return value.isEmpty ? fallback : value
    }

    /// Free all resources (call on app quit / model deletion). `llama_backend_free` is called
    /// once when the last runtime releases so the Metal devices tear down before process exit.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        shutdownLocked()
    }

    deinit {
        shutdown()
    }

    private func shutdownLocked() {
        if let samplerChain { llama_sampler_free(samplerChain); self.samplerChain = nil }
        if let context { llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        loadedURL = nil
        loadedSamplerKey = nil
        loadedPromptFamily = nil
        gemmaTemplate = nil
        if holdsBackendLease {
            BackendLifecycle.release()
            holdsBackendLease = false
        }
    }
}
