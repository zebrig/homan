import Foundation
import LlamaSwift

/// In-process GGUF runtime over `mattt/llama.swift` (llama.cpp b10276, Metal).
///
/// Replaces the LLM.swift `bot` inside `GemmaSummaryBackend` for on-device summarization.
/// Config matches the A2 recon (spec 005 Phase 0): full Metal offload, `n_batch=2048`
/// chunked prefill, `n_ubatch=512`, flash attention on, chat template rendered via
/// `llama_chat_apply_template(nil, …)` (passing an explicit template string returns -1
/// for Gemma 4; NULL uses the model's embedded jinja template).
///
/// Not an actor: it is serialized externally by `GemmaSummaryBackend` (actor + InferenceGate)
/// and additionally guards its own state with an `NSLock`.
final class SummaryRuntime {
    private let lock = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    // llama.swift 2.10280+ exposes llama_sampler as a concrete struct (b10276 was opaque).
    private var samplerChain: UnsafeMutablePointer<llama_sampler>?
    private var loadedURL: URL?
    private var loadedSamplerKey: String?
    private static var backendInitialized = false

    static let defaultContextTokens: Int32 = 32_768
    /// llama-cli's default; n_batch=512 was measurably slower on the M4 (7.9 vs 11.3 t/s QAT).
    static let batchSize = 2048

    // MARK: - Loading

    /// Load a GGUF model into Metal and prepare a sampler chain. Returns false when the
    /// model file is missing or loading fails. Reloads only when the model/sampler key changes.
    @discardableResult
    func load(
        modelURL: URL,
        contextTokens: Int32,
        topK: Int32,
        topP: Float,
        temp: Float,
        seed: UInt32
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let samplerKey = "\(contextTokens)|\(topK)|\(topP)|\(temp)"
        if let loadedURL, loadedURL == modelURL, loadedSamplerKey == samplerKey, model != nil {
            return true
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return false }

        if !Self.backendInitialized {
            llama_backend_init()
            Self.backendInitialized = true
        }
        shutdownLocked()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else { return false }

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextTokens)
        cparams.n_batch = UInt32(Self.batchSize)
        cparams.n_ubatch = UInt32(Self.batchSize)
        cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        cparams.n_threads = Int32(ProcessInfo.processInfo.processorCount)
        cparams.n_threads_batch = Int32(ProcessInfo.processInfo.processorCount)
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            return false
        }

        var sparams = llama_sampler_chain_default_params()
        sparams.no_perf = true
        guard let chain = llama_sampler_chain_init(sparams) else {
            llama_free(c)
            llama_model_free(m)
            return false
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temp))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(seed))

        model = m
        context = c
        vocab = llama_model_get_vocab(m)
        samplerChain = chain
        loadedURL = modelURL
        loadedSamplerKey = samplerKey
        return true
    }

    // MARK: - Generation

    /// Generate one assistant turn for a system+user prompt. Returns raw text; the caller
    /// strips thinking/markers via `GemmaSummaryOutputCleaner`. Clears the KV cache per call
    /// so the context can be reused across turns. Empty string on any failure.
    func respond(systemPrompt: String, userPrompt: String, maxOutputTokens: Int32) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let context, let vocab, let samplerChain else { return "" }

        // b10276 renamed kv_cache_clear → llama_memory_clear(llama_get_memory(ctx), data:)
        llama_memory_clear(llama_get_memory(context), true)

        let sysRole = strdup("system")!
        let userRole = strdup("user")!
        let sysC = strdup(systemPrompt)!
        let userC = strdup(userPrompt)!
        defer { free(sysRole); free(userRole); free(sysC); free(userC) }

        var chat: [llama_chat_message] = []
        var m0 = llama_chat_message(); m0.role = UnsafePointer(sysRole); m0.content = UnsafePointer(sysC)
        chat.append(m0)
        var m1 = llama_chat_message(); m1.role = UnsafePointer(userRole); m1.content = UnsafePointer(userC)
        chat.append(m1)

        let rendered: String = chat.withUnsafeBufferPointer { buf -> String in
            let cap: Int32 = 64 * 1024 * 1024
            var out = [CChar](repeating: 0, count: Int(cap))
            let n = llama_chat_apply_template(nil, buf.baseAddress, buf.count, true, &out, cap)
            guard n >= 0 else { return "" }
            return String(cString: out)
        }
        guard !rendered.isEmpty else { return "" }

        var promptTokens = [llama_token](repeating: 0, count: rendered.utf8.count + 64)
        let nPrompt = llama_tokenize(vocab, rendered, Int32(rendered.utf8.count), &promptTokens, Int32(promptTokens.count), true, true)
        guard nPrompt > 0 else { return "" }
        promptTokens = Array(promptTokens.prefix(Int(nPrompt)))

        var code: Int32 = 0
        var pos = 0
        while pos < promptTokens.count {
            let n = min(Self.batchSize, promptTokens.count - pos)
            var slice = Array(promptTokens[pos..<(pos + n)])
            let batch = llama_batch_get_one(&slice, Int32(n))
            code = llama_decode(context, batch)
            if code != 0 { return "" }
            pos += n
        }

        let eos = llama_vocab_eos(vocab)
        var outTokens: [llama_token] = []
        outTokens.reserveCapacity(Int(maxOutputTokens))
        var token = llama_sampler_sample(samplerChain, context, -1)
        while token != eos && outTokens.count < Int(maxOutputTokens) {
            outTokens.append(token)
            var one = token
            let genBatch = llama_batch_get_one(&one, 1)
            code = llama_decode(context, genBatch)
            if code != 0 { break }
            token = llama_sampler_sample(samplerChain, context, -1)
        }

        var text = ""
        text.reserveCapacity(outTokens.count * 4)
        for t in outTokens {
            var piece = [CChar](repeating: 0, count: 64)
            let n = llama_token_to_piece(vocab, t, &piece, Int32(piece.count), 0, false)
            if n > 0 { text += String(cString: piece) }
        }
        return text
    }

    /// Free all resources (call on app quit / model deletion). `llama_backend_free` is called
    /// once when the last runtime releases so the Metal devices tear down before process exit.
    func shutdown() {
        lock.lock(); defer { lock.unlock() }
        shutdownLocked()
    }

    private func shutdownLocked() {
        if let samplerChain { llama_sampler_free(samplerChain); self.samplerChain = nil }
        if let context { llama_free(context); self.context = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        loadedURL = nil
        loadedSamplerKey = nil
        if Self.backendInitialized {
            llama_backend_free()
            Self.backendInitialized = false
        }
    }
}
