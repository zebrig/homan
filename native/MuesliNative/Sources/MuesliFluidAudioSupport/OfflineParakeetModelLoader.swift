@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Loads Homan-managed Parakeet packages without invoking FluidAudio's
/// download-or-repair path. A load failure is returned to Homan; this loader
/// never removes model files and never performs network I/O.
public enum OfflineParakeetModelLoader {
    public enum LoaderError: Error, LocalizedError, Sendable {
        case unsupportedVersion
        case invalidVocabulary(URL)

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion:
                return "Only Parakeet v2 and v3 packages can be loaded by Homan's offline loader."
            case .invalidVocabulary(let url):
                return "The Parakeet vocabulary is invalid: \(url.path)"
            }
        }
    }

    public static func load(
        from directory: URL,
        version: AsrModelVersion
    ) async throws -> AsrModels {
        let jointFileName: String
        switch version {
        case .v2:
            jointFileName = "JointDecision.mlmodelc"
        case .v3:
            jointFileName = "JointDecisionv3.mlmodelc"
        default:
            throw LoaderError.unsupportedVersion
        }

        let configuration = AsrModels.defaultConfiguration()
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly
        preprocessorConfiguration.allowLowPrecisionAccumulationOnGPU = true

        try Task.checkCancellation()
        let preprocessor = try MLModel(
            contentsOf: directory.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true),
            configuration: preprocessorConfiguration
        )
        try Task.checkCancellation()
        let encoder = try MLModel(
            contentsOf: directory.appendingPathComponent("Encoder.mlmodelc", isDirectory: true),
            configuration: configuration
        )
        try Task.checkCancellation()
        let decoder = try MLModel(
            contentsOf: directory.appendingPathComponent("Decoder.mlmodelc", isDirectory: true),
            configuration: configuration
        )
        try Task.checkCancellation()
        let joint = try MLModel(
            contentsOf: directory.appendingPathComponent(jointFileName, isDirectory: true),
            configuration: configuration
        )
        try Task.checkCancellation()
        let vocabulary = try loadVocabulary(
            from: directory.appendingPathComponent("parakeet_vocab.json")
        )

        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: version
        )
    }

    static func loadVocabulary(from url: URL) throws -> [Int: String] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        if let tokens = object as? [String] {
            return Dictionary(uniqueKeysWithValues: tokens.enumerated().map { ($0.offset, $0.element) })
        }
        if let tokens = object as? [String: String] {
            let vocabulary = Dictionary(uniqueKeysWithValues: tokens.compactMap { key, value in
                Int(key).map { ($0, value) }
            })
            guard vocabulary.count == tokens.count else {
                throw LoaderError.invalidVocabulary(url)
            }
            return vocabulary
        }
        throw LoaderError.invalidVocabulary(url)
    }
}
