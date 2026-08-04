import FluidAudio
import Foundation

/// Native Swift transcription backend using FluidAudio's Qwen3 ASR model
/// running on Apple's Neural Engine (ANE) via CoreML.
/// Requires macOS 15+ due to CoreML stateful decoder support.
@available(macOS 15, *)
actor Qwen3AsrTranscriber {
    private var manager: Qwen3AsrManager?

    enum TranscriberError: Error, LocalizedError {
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notLoaded:
                return "Qwen3 ASR models not loaded. Call loadModels() first."
            }
        }
    }

    /// Downloads models (if needed) and initializes the Qwen3 ASR manager.
    func loadModels(progress: ((Double, String?) -> Void)? = nil) async throws {
        if manager != nil { return }

        fputs("[qwen3-asr] downloading/loading models...\n", stderr)
        let modelDir = try await Qwen3AsrModels.download(variant: .int8) { downloadProgress in
            let fraction = downloadProgress.fractionCompleted
            DispatchQueue.main.async {
                progress?(fraction, "Downloading Qwen3 ASR...")
            }
        }
        let mgr = Qwen3AsrManager()
        try await mgr.loadModels(from: modelDir)
        self.manager = mgr
        fputs("[qwen3-asr] models loaded, running warmup inference...\n", stderr)

        // Warmup: run a tiny dummy audio through the pipeline to trigger CoreML compilation.
        // This moves the ~30s compilation cost from first dictation to preload time.
        let warmupSamples = [Float](repeating: 0, count: 16000) // 1 second of silence
        _ = try? await mgr.transcribe(audioSamples: warmupSamples)
        fputs("[qwen3-asr] warmup complete, ready\n", stderr)
    }

    /// Transcribe a WAV file URL.
    /// Returns the transcribed text (no token-level timings available).
    func transcribe(wavURL: URL) async throws -> (text: String, processingTime: Double) {
        guard let manager else { throw TranscriberError.notLoaded }
        let start = CFAbsoluteTimeGetCurrent()
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(wavURL)
        let text = try await manager.transcribe(audioSamples: samples)
        let processingTime = CFAbsoluteTimeGetCurrent() - start
        return (text, processingTime)
    }

    func shutdown() {
        manager = nil
    }
}
