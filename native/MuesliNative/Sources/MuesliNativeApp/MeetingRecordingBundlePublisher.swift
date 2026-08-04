import Foundation

enum MeetingRecordingBundlePublisherError: Error, LocalizedError {
    case stagingOutsideManagedRoot
    case missingStagedSource(MeetingAudioSourceRole)
    case sessionCollision

    var errorDescription: String? {
        switch self {
        case .stagingOutsideManagedRoot:
            return "The meeting source staging directory is outside Homan's managed storage."
        case .missingStagedSource(let source):
            return "The staged \(source.rawValue) meeting source is missing."
        case .sessionCollision:
            return "A different meeting source bundle already uses this recording session ID."
        }
    }
}

enum MeetingRecordingBundlePublisher {
    static func publish(
        stagedRawAudio: MeetingStagedRawAudio,
        playbackURL: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingBundle {
        try validateRawStaging(
            stagedRawAudio,
            supportDirectory: supportDirectory
        )
        let sourcesRoot = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent(MeetingRecordingBundle.sourceDirectoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: sourcesRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let stagedManifest = stagedRawAudio.manifest
        let sessionName = stagedManifest.sessionID.uuidString.lowercased()
        let destination = sourcesRoot.appendingPathComponent(sessionName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try MeetingRecordingBundle.load(
                directoryURL: destination,
                supportDirectory: supportDirectory,
                fileManager: fileManager
            )
            guard existing.manifest.sessionID == stagedManifest.sessionID,
                  existing.manifest.meetingID == stagedManifest.meetingID else {
                throw MeetingRecordingBundlePublisherError.sessionCollision
            }
            return existing
        }

        let pending = sourcesRoot.appendingPathComponent(
            ".pending-\(sessionName)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: pending,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            var rawManifest = stagedManifest
            rawManifest.microphoneEpochs = try copyRawEpochs(
                stagedManifest.microphoneEpochs,
                stagedAudio: stagedRawAudio,
                pendingDirectory: pending,
                fileManager: fileManager
            )
            rawManifest.systemEpochs = try copyRawEpochs(
                stagedManifest.systemEpochs,
                stagedAudio: stagedRawAudio,
                pendingDirectory: pending,
                fileManager: fileManager
            )
            let manifest = makeRawManifest(
                rawAudio: rawManifest,
                playbackURL: playbackURL
            )
            let manifestURL = pending.appendingPathComponent(
                MeetingRecordingBundle.manifestFilename
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            do {
                try fileManager.moveItem(at: pending, to: destination)
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: pending)
                    let existing = try MeetingRecordingBundle.load(
                        directoryURL: destination,
                        supportDirectory: supportDirectory,
                        fileManager: fileManager
                    )
                    guard existing.manifest.sessionID == stagedManifest.sessionID else {
                        throw MeetingRecordingBundlePublisherError.sessionCollision
                    }
                    return existing
                }
                throw error
            }
            return try MeetingRecordingBundle.load(
                directoryURL: destination,
                supportDirectory: supportDirectory,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: pending)
            throw error
        }
    }

    static func publish(
        stagedAudio: MeetingStagedAudio,
        playbackURL: URL,
        supportDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingRecordingBundle {
        try validateStaging(stagedAudio, supportDirectory: supportDirectory)

        let sourcesRoot = supportDirectory
            .appendingPathComponent("meeting-recordings", isDirectory: true)
            .appendingPathComponent(MeetingRecordingBundle.sourceDirectoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: sourcesRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let sessionName = stagedAudio.manifest.sessionID.uuidString.lowercased()
        let destination = sourcesRoot.appendingPathComponent(sessionName, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            let existing = try MeetingRecordingBundle.load(
                directoryURL: destination,
                supportDirectory: supportDirectory,
                fileManager: fileManager
            )
            guard existing.manifest.sessionID == stagedAudio.manifest.sessionID,
                  existing.manifest.meetingID == stagedAudio.manifest.meetingID else {
                throw MeetingRecordingBundlePublisherError.sessionCollision
            }
            return existing
        }

        let pending = sourcesRoot.appendingPathComponent(
            ".pending-\(sessionName)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: pending,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let microphoneName = "mic-cleaned.wav"
            let systemName = "system.wav"
            try copySource(
                stagedAudio.microphoneURL,
                to: pending.appendingPathComponent(microphoneName),
                expectedSamples: stagedAudio.manifest.microphoneSampleCount,
                role: .microphone,
                fileManager: fileManager
            )
            try copySource(
                stagedAudio.systemURL,
                to: pending.appendingPathComponent(systemName),
                expectedSamples: stagedAudio.manifest.systemSampleCount,
                role: .system,
                fileManager: fileManager
            )

            let manifest = makeManifest(
                stagedAudio: stagedAudio,
                playbackURL: playbackURL,
                microphoneName: microphoneName,
                systemName: systemName
            )
            let manifestURL = pending.appendingPathComponent(
                MeetingRecordingBundle.manifestFilename
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )

            do {
                try fileManager.moveItem(at: pending, to: destination)
            } catch {
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: pending)
                    let existing = try MeetingRecordingBundle.load(
                        directoryURL: destination,
                        supportDirectory: supportDirectory,
                        fileManager: fileManager
                    )
                    guard existing.manifest.sessionID == stagedAudio.manifest.sessionID else {
                        throw MeetingRecordingBundlePublisherError.sessionCollision
                    }
                    return existing
                }
                throw error
            }

            return try MeetingRecordingBundle.load(
                directoryURL: destination,
                supportDirectory: supportDirectory,
                fileManager: fileManager
            )
        } catch {
            try? fileManager.removeItem(at: pending)
            throw error
        }
    }

    private static func validateStaging(
        _ stagedAudio: MeetingStagedAudio,
        supportDirectory: URL
    ) throws {
        let root = supportDirectory
            .appendingPathComponent(MeetingProcessingCapture.directoryName, isDirectory: true)
            .standardizedFileURL
        let directory = stagedAudio.directoryURL.standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/") else {
            throw MeetingRecordingBundlePublisherError.stagingOutsideManagedRoot
        }
    }

    private static func validateRawStaging(
        _ stagedAudio: MeetingStagedRawAudio,
        supportDirectory: URL
    ) throws {
        let root = supportDirectory
            .appendingPathComponent(MeetingRawAudioCapture.directoryName, isDirectory: true)
            .standardizedFileURL
        let directory = stagedAudio.directoryURL.standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/") else {
            throw MeetingRecordingBundlePublisherError.stagingOutsideManagedRoot
        }
    }

    private static func copyRawEpochs(
        _ epochs: [MeetingRawAudioEpoch],
        stagedAudio: MeetingStagedRawAudio,
        pendingDirectory: URL,
        fileManager: FileManager
    ) throws -> [MeetingRawAudioEpoch] {
        try epochs.map { epoch in
            let sourceURL = stagedAudio.payloadURL(for: epoch).standardizedFileURL
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw MeetingRecordingBundlePublisherError.missingStagedSource(
                    epoch.role
                )
            }
            let extensionName = sourceURL.pathExtension.isEmpty
                ? (epoch.encoding == .appleLossless ? "caf" : "pcm")
                : sourceURL.pathExtension
            let relativePath =
                "raw/\(epoch.role.rawValue)/\(epoch.id.uuidString.lowercased()).\(extensionName)"
            let destinationURL = pendingDirectory.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            var copied = epoch
            copied.relativePath = relativePath
            return copied
        }
    }

    private static func copySource(
        _ sourceURL: URL,
        to destinationURL: URL,
        expectedSamples: Int,
        role: MeetingAudioSourceRole,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            if expectedSamples == 0 { return }
            throw MeetingRecordingBundlePublisherError.missingStagedSource(role)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    private static func makeManifest(
        stagedAudio: MeetingStagedAudio,
        playbackURL: URL,
        microphoneName: String,
        systemName: String
    ) -> MeetingRecordingBundleManifest {
        let staged = stagedAudio.manifest
        return MeetingRecordingBundleManifest(
            schemaVersion: MeetingRecordingBundleManifest.legacySchemaVersion,
            meetingID: staged.meetingID,
            recordingID: nil,
            sessionID: staged.sessionID,
            startedAt: staged.startedAt,
            endedAt: staged.endedAt ?? staged.startedAt,
            timelinePolicy: staged.timelinePolicy ?? .activeCaptureCompacted,
            sampleRate: staged.sampleRate,
            channelsPerSource: staged.channels,
            microphone: MeetingRecordingSourceDescriptor(
                role: .microphone,
                relativePath: microphoneName,
                sampleCount: staged.microphoneSampleCount,
                encoding: .pcmS16LEWAV,
                availability: staged.microphoneSampleCount > 0 ? .available : .empty,
                contentDigest: nil
            ),
            system: MeetingRecordingSourceDescriptor(
                role: .system,
                relativePath: systemName,
                sampleCount: staged.systemSampleCount,
                encoding: .pcmS16LEWAV,
                availability: staged.systemSampleCount > 0 ? .available : .empty,
                contentDigest: nil
            ),
            preprocessing: staged.preprocessing ?? .current,
            captureModelSnapshot: MeetingRecordingModelSnapshot(
                modelID: staged.finalModelID,
                languages: MeetingLanguageSnapshot(
                    cohereLanguage: staged.cohereLanguage,
                    indicASRLanguage: staged.indicASRLanguage,
                    nemotron35Language: staged.nemotron35Language
                )
            ),
            playback: MeetingRecordingPlaybackDescriptor(
                relativeOrAbsolutePath: playbackURL.standardizedFileURL.path,
                format: playbackURL.pathExtension.lowercased()
            ),
            rawAudio: nil
        )
    }

    private static func makeRawManifest(
        rawAudio: MeetingRawAudioManifest,
        playbackURL: URL
    ) -> MeetingRecordingBundleManifest {
        let microphoneFrames = rawAudio.microphoneEpochs.reduce(0) {
            $0 + $1.frameCount
        }
        let systemFrames = rawAudio.systemEpochs.reduce(0) {
            $0 + $1.frameCount
        }
        return MeetingRecordingBundleManifest(
            schemaVersion: MeetingRecordingBundleManifest.currentSchemaVersion,
            meetingID: rawAudio.meetingID,
            recordingID: nil,
            sessionID: rawAudio.sessionID,
            startedAt: rawAudio.startedAt,
            endedAt: rawAudio.endedAt ?? rawAudio.startedAt,
            timelinePolicy: .activeCaptureCompacted,
            sampleRate: 0,
            channelsPerSource: 0,
            microphone: MeetingRecordingSourceDescriptor(
                role: .microphone,
                relativePath: "raw/microphone",
                sampleCount: microphoneFrames,
                encoding: .nativeLosslessEpochs,
                availability: microphoneFrames > 0 ? .available : .empty,
                contentDigest: nil
            ),
            system: MeetingRecordingSourceDescriptor(
                role: .system,
                relativePath: "raw/system",
                sampleCount: systemFrames,
                encoding: .nativeLosslessEpochs,
                availability: systemFrames > 0 ? .available : .empty,
                contentDigest: nil
            ),
            preprocessing: .rawSources,
            captureModelSnapshot: MeetingRecordingModelSnapshot(
                modelID: rawAudio.finalModelID,
                languages: MeetingLanguageSnapshot(
                    cohereLanguage: rawAudio.cohereLanguage,
                    indicASRLanguage: rawAudio.indicASRLanguage,
                    nemotron35Language: rawAudio.nemotron35Language
                )
            ),
            playback: MeetingRecordingPlaybackDescriptor(
                relativeOrAbsolutePath: playbackURL.standardizedFileURL.path,
                format: playbackURL.pathExtension.lowercased()
            ),
            rawAudio: rawAudio
        )
    }
}
