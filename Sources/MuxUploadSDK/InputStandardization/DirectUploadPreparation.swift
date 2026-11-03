//
//  DirectUploadPreparation.swift
//

import AVFoundation
import Foundation
import VideoToolbox

protocol StandardInputPlanningCapabilityProviding: Sendable {
    func capabilities(
        for inspection: UploadInputFormatInspectionResult,
        sourceAsset: AVAsset
    ) async -> StandardInputPlanningCapabilities
}

struct AVFoundationStandardInputPlanningCapabilityProvider:
    StandardInputPlanningCapabilityProviding {
    func capabilities(
        for inspection: UploadInputFormatInspectionResult,
        sourceAsset: AVAsset
    ) async -> StandardInputPlanningCapabilities {
        var codecs: Set<StandardInputVideoCodec> = []
        if canCreateCompressionSession(codec: kCMVideoCodecType_H264) {
            codecs.insert(.h264)
        }
        if canCreateCompressionSession(codec: kCMVideoCodecType_HEVC) {
            codecs.insert(.hevc)
        }
        return StandardInputPlanningCapabilities(
            sourceIsDecodable: await canDecodeVideoSample(
                from: sourceAsset,
                expectedTrackCount: inspection.metadata.videoTrackCount
            ),
            encodableVideoCodecs: codecs,
            remediableRequirements: Set(StandardInputPolicyEvaluation.Requirement.allCases),
            toneMappableDynamicRanges: [.hlg, .pq],
            preservableHDRDynamicRanges: [.hlg, .pq]
        )
    }

    /// Starts a bounded decode and requests one decompressed pixel buffer. A
    /// track count alone only proves that compressed samples are present.
    private func canDecodeVideoSample(
        from asset: AVAsset,
        expectedTrackCount: Int
    ) async -> Bool {
        guard expectedTrackCount == 1,
              let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else {
            return false
        }
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        return output.copyNextSampleBuffer() != nil
    }

    private func canCreateCompressionSession(codec: CMVideoCodecType) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 16,
            height: 16,
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        return status == noErr
    }
}

protocol TemporaryStoragePreflighting: Sendable {
    func outputURL(
        for sourceURL: URL,
        duration: CMTime,
        conversion: StandardInputConversion
    ) throws -> URL

    func ownsTemporaryOutput(_ url: URL) -> Bool
}

struct TemporaryStoragePreflightError: LocalizedError {
    enum Reason {
        case unavailableCapacity
        case insufficientCapacity(required: Int64, available: Int64)
        case cannotCreateDirectory
    }

    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .unavailableCapacity:
            return "Temporary storage capacity could not be determined"
        case .insufficientCapacity(let required, let available):
            return "Insufficient temporary storage: requires \(required) bytes, \(available) bytes available"
        case .cannotCreateDirectory:
            return "The temporary standardization directory could not be created"
        }
    }
}

struct FileSystemTemporaryStoragePreflighter: TemporaryStoragePreflighting {
    static let directoryName = "MuxUploadSDK/Standardized"
    static let filePrefix = "mux-upload-"
    static let reserveBytes: Int64 = 64 * 1_024 * 1_024

    static var durableBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private let baseDirectory: URL

    init(
        baseDirectory: URL = Self.durableBaseDirectory
    ) {
        self.baseDirectory = baseDirectory
    }

    func outputURL(
        for sourceURL: URL,
        duration: CMTime,
        conversion: StandardInputConversion
    ) throws -> URL {
        let directory = try makeOutputDirectory()

        let available = try availableCapacity(at: directory)
        let required = requiredCapacity(
            sourceURL: sourceURL,
            duration: duration,
            conversion: conversion
        )
        guard available >= required else {
            throw TemporaryStoragePreflightError(
                reason: .insufficientCapacity(required: required, available: available)
            )
        }

        return directory.appendingPathComponent(
            "\(Self.filePrefix)\(UUID().uuidString).mp4"
        )
    }

    private func makeOutputDirectory() throws -> URL {
        var directory = baseDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw TemporaryStoragePreflightError(reason: .cannotCreateDirectory)
        }

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }

    func ownsTemporaryOutput(_ url: URL) -> Bool {
        let directory = baseDirectory.appendingPathComponent(Self.directoryName).standardizedFileURL
        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.directoryName).standardizedFileURL
        let candidate = url.standardizedFileURL
        return candidate.isFileURL && candidate.lastPathComponent.hasPrefix(Self.filePrefix)
            && (candidate.deletingLastPathComponent() == directory
                || candidate.deletingLastPathComponent() == legacyDirectory)
    }

    /// Resolve SDK paths in the current container and move legacy tmp payloads
    /// without regenerating bytes or changing the saved checkpoint.
    func restoredOutputURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        let parent = candidate.deletingLastPathComponent().path
        let durableSuffix = "/Library/Application Support/" + Self.directoryName
        let legacySuffix = "/tmp/" + Self.directoryName
        guard candidate.isFileURL, candidate.lastPathComponent.hasPrefix(Self.filePrefix),
              ownsTemporaryOutput(candidate) || parent.hasSuffix(durableSuffix)
                || parent.hasSuffix(legacySuffix) else { return url }

        let destination = baseDirectory.appendingPathComponent(Self.directoryName)
            .appendingPathComponent(candidate.lastPathComponent)
        guard candidate != destination else { return destination }
        // Also recovers a move completed before the updated uploads.json was written.
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let legacy = FileManager.default.temporaryDirectory.appendingPathComponent(Self.directoryName)
            .appendingPathComponent(candidate.lastPathComponent)
        let source = FileManager.default.fileExists(atPath: candidate.path) ? candidate : legacy
        if FileManager.default.fileExists(atPath: source.path) {
            _ = try makeOutputDirectory()
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return destination
    }

    private func availableCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        throw TemporaryStoragePreflightError(reason: .unavailableCapacity)
    }

    private func requiredCapacity(
        sourceURL: URL,
        duration: CMTime,
        conversion: StandardInputConversion
    ) -> Int64 {
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        let durationSeconds = duration.seconds
        let tier = conversion.selection.acceptanceTier
        let videoBitrate = StandardInputPolicyProfile.publishedMux
            .limits(for: tier)
            .maximumAverageBitrate
        let estimatedOutput: Int64
        if durationSeconds.isFinite, durationSeconds > 0 {
            let estimated = durationSeconds * Double(videoBitrate + 512_000) / 8
            estimatedOutput = estimated < Double(Int64.max)
                ? Int64(estimated.rounded(.up))
                : Int64.max
        } else {
            estimatedOutput = sourceSize
        }
        let payload = max(sourceSize, estimatedOutput)
        let (required, overflow) = payload.addingReportingOverflow(Self.reserveBytes)
        return overflow ? Int64.max : required
    }

}
