import ArgumentParser
import Foundation
import MuesliCore

// MARK: - Download state file

/// Durable, atomic download state written by the CLI and read by the app.
/// Lives at Application Support/<App>/model-downloads/<id>.json
struct DownloadStateFile: Codable {
    enum Status: String, Codable {
        case downloading
        case done
        case error
    }

    var status: Status
    var bytes: Int64
    var total: Int64?
    var error: String?
    var sha256: String?

    static func read(at url: URL) -> DownloadStateFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DownloadStateFile.self, from: data)
    }

    /// Atomic write: write to a temp file then rename over the destination so a
    /// reader never observes a partially-written state file.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tempURL, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}

// MARK: - Downloader

enum DownloadModelError: LocalizedError {
    case missingArguments
    case badURL(String)
    case httpError(Int, String)
    case sha256Mismatch(expected: String, actual: String)
    case unexpectedEOF(Int64, Int64)

    var errorDescription: String? {
        switch self {
        case .missingArguments:
            return "download-model requires --id, --url, and --dest."
        case .badURL(let url):
            return "Invalid download URL: \(url)"
        case .httpError(let code, let path):
            return "HTTP \(code) downloading \(path)"
        case .sha256Mismatch(let expected, let actual):
            return "SHA-256 mismatch. Expected \(expected), got \(actual)."
        case .unexpectedEOF(let have, let want):
            return "Unexpected end of stream: have \(have) of \(want) bytes."
        }
    }
}

/// HTTP streaming downloader with resume support (Range requests against a
/// `<dest>.partial` file) and periodic state-file progress writes.
///
/// Kept dependency-free (Foundation only) so it can run in the detached
/// `homan-cli` process without touching the app's network stack.
enum ModelFileDownloader {
    private static let progressFlushInterval: TimeInterval = 0.5

    /// Download `url` to `dest`. Resumes from an existing `<dest>.partial` file.
    /// `stateFileURL` is written atomically on progress, completion, and error.
    static func download(
        url: URL,
        to dest: URL,
        expectedSize: Int64?,
        expectedSHA256: String?,
        stateFileURL: URL,
        stateID: String
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partialURL = dest.appendingPathExtension("partial")

        let existingBytes = (try? fm.attributesOfItem(atPath: partialURL.path)[.size] as? Int64) ?? 0
        var downloadedBytes = existingBytes

        // If we already have a complete file at the destination, we're done.
        if fm.fileExists(atPath: dest.path) {
            try writeState(.done, bytes: downloadedBytes, total: expectedSize, stateFileURL: stateFileURL)
            return
        }

        var request = URLRequest(url: url)
        if downloadedBytes > 0 {
            request.setValue("bytes=\(downloadedBytes)-", forHTTPHeaderField: "Range")
        }
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadModelError.httpError(-1, url.lastPathComponent)
        }
        // 206 = resumed from a Range request. 200 = server ignored Range (no resume
        // support) → discard any partial and restart from zero.
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw DownloadModelError.httpError(http.statusCode, url.lastPathComponent)
        }
        if http.statusCode == 200, downloadedBytes > 0 {
            downloadedBytes = 0
            try? fm.removeItem(at: partialURL)
        }

        let totalBytes = expectedSize ?? (http.expectedContentLength > 0 ? http.expectedContentLength + downloadedBytes : nil)

        try writeState(.downloading, bytes: downloadedBytes, total: totalBytes, stateFileURL: stateFileURL)

        // Open the partial file in append mode.
        let handle = try FileHandle(forWritingTo: ensurePartialFile(at: partialURL, createIfMissing: downloadedBytes == 0))
        defer { try? handle.close() }
        if downloadedBytes == 0 {
            try handle.truncate(atOffset: 0)
        } else {
            try handle.seek(toOffset: UInt64(downloadedBytes))
        }

        var lastFlush = Date.distantPast
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            downloadedBytes += 1
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            if Date().timeIntervalSince(lastFlush) >= progressFlushInterval {
                lastFlush = Date()
                try writeState(.downloading, bytes: downloadedBytes, total: totalBytes, stateFileURL: stateFileURL)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()

        // Verify length + checksum before installing.
        if let totalBytes, downloadedBytes != totalBytes {
            throw DownloadModelError.unexpectedEOF(downloadedBytes, totalBytes)
        }
        if let expectedSHA256 {
            let actual = try sha256(of: partialURL)
            guard actual == expectedSHA256.lowercased() else {
                throw DownloadModelError.sha256Mismatch(expected: expectedSHA256, actual: actual)
            }
        }

        // Install: remove any stale destination, move partial → dest.
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: partialURL, to: dest)

        try writeState(.done, bytes: downloadedBytes, total: totalBytes, stateFileURL: stateFileURL)
    }

    private static func ensurePartialFile(at url: URL, createIfMissing: Bool) -> URL {
        let fm = FileManager.default
        if createIfMissing && !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private static func writeState(
        _ status: DownloadStateFile.Status,
        bytes: Int64,
        total: Int64?,
        stateFileURL: URL
    ) throws {
        try DownloadStateFile(
            status: status,
            bytes: bytes,
            total: total,
            error: nil,
            sha256: nil
        ).write(to: stateFileURL)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Digest()
        while let chunk = try handle.read(upToCount: 1 << 20) {
            hasher.update(chunk)
        }
        return hasher.hexDigest
    }
}

/// Minimal incremental SHA-256 (avoids importing CryptoSwift in the CLI).
struct SHA256Digest {
    // SHA-256 constants.
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var pending = Data()
    private var totalLength: UInt64 = 0

    mutating func update(_ data: Data) {
        totalLength += UInt64(data.count)
        pending.append(data)
        while pending.count >= 64 {
            let block = pending.prefix(64)
            processBlock(Array(block))
            pending.removeFirst(64)
        }
    }

    mutating func finalize() -> Data {
        let bitLength = totalLength * 8
        pending.append(0x80)
        while pending.count % 64 != 56 {
            pending.append(0)
        }
        var lengthBytes = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            lengthBytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }
        pending.append(lengthBytes)
        while !pending.isEmpty {
            let block = pending.prefix(64)
            processBlock(Array(block))
            pending.removeFirst(64)
        }
        var digest = Data()
        for value in h {
            for shift in stride(from: 24, through: 0, by: -8) {
                digest.append(UInt8((value >> UInt32(shift)) & 0xff))
            }
        }
        return digest
    }

    var hexDigest: String {
        var copy = self
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func processBlock(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = (UInt32(block[i * 4]) << 24)
                | (UInt32(block[i * 4 + 1]) << 16)
                | (UInt32(block[i * 4 + 2]) << 8)
                | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0], b = h[1], c = h[2], d = h[3]
        var e = h[4], f = h[5], g = h[6], hh = h[7]

        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj
            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] &+= a
        h[1] &+= b
        h[2] &+= c
        h[3] &+= d
        h[4] &+= e
        h[5] &+= f
        h[6] &+= g
        h[7] &+= hh
    }

    private func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
        (value >> bits) | (value << (32 - bits))
    }
}

// MARK: - Command

struct DownloadModelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download-model",
        abstract: "Download a model file with resume support, writing progress to a state file that survives app restarts."
    )

    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Stable identifier for this download (also the state-file name).")
    var id: String
    @Option(name: .long, help: "Absolute destination path for the downloaded file.")
    var dest: String
    @Option(name: .long, help: "Download URL.")
    var url: String
    @Option(name: .long, help: "Expected total size in bytes (optional; used for progress total and EOF check).")
    var expectedSize: Int64?
    @Option(name: .long, help: "Expected SHA-256 hex digest (optional; verified before the file is installed).")
    var sha256: String?

    func run() async throws {
        guard !id.isEmpty, !url.isEmpty, !dest.isEmpty else {
            throw DownloadModelError.missingArguments
        }
        guard let downloadURL = URL(string: url) else {
            throw DownloadModelError.badURL(url)
        }
        let context = CLIContext(options: global)
        let destURL = URL(fileURLWithPath: dest)
        let stateFileURL = context.supportDirectory
            .appendingPathComponent("model-downloads", isDirectory: true)
            .appendingPathComponent("\(id).json")

        do {
            try await ModelFileDownloader.download(
                url: downloadURL,
                to: destURL,
                expectedSize: expectedSize,
                expectedSHA256: sha256,
                stateFileURL: stateFileURL,
                stateID: id
            )
            emitSuccess(
                command: "homan-cli download-model",
                data: ["id": id, "dest": dest, "status": "done"],
                dbPath: context.databaseURL
            )
        } catch {
            // Write the failure to the state file so the app sees a terminal error.
            let state = DownloadStateFile(status: .error, bytes: 0, total: expectedSize, error: error.localizedDescription, sha256: nil)
            try? state.write(to: stateFileURL)
            throw error
        }
    }
}
