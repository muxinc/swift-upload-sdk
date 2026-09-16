//
//  UploadInputInspector.swift
//  

@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct UploadInputInspectionOutcome: Sendable {
    let result: UploadInputFormatInspectionResult?
    let duration: CMTime
    let error: Error?
}

typealias UploadInputInspectionCompletionHandler = (
    UploadInputFormatInspectionResult?,
    CMTime,
    Error?
) -> Void

actor UploadInputInspectionOperation {
    private enum State {
        case active
        case cancelled
        case completed
    }

    private var state: State = .active
    private var hasRegisteredReader = false

    var isCancelled: Bool {
        state == .cancelled
    }

    var hasRegisteredAssetReader: Bool {
        hasRegisteredReader
    }

    func register(assetReader: AVAssetReader) -> Bool {
        guard state == .active else {
            assetReader.cancelReading()
            return false
        }
        hasRegisteredReader = true
        return true
    }

    func cancel() {
        guard state == .active else { return }
        // AVAssetReader forbids calling cancelReading() concurrently with
        // copyNextSampleBuffer(). Record cancellation here; the task consuming
        // samples observes this state and cancels its reader on that same task.
        state = .cancelled
    }

    func complete() -> Bool {
        guard state == .active else { return false }
        state = .completed
        hasRegisteredReader = false
        return true
    }
}

actor UploadInputInspectionOperationRegistry {
    struct Token: Equatable, Sendable {
        private let id: UUID

        init() {
            self.id = UUID()
        }
    }

    private struct Registration {
        let token: Token
        let operation: UploadInputInspectionOperation
    }

    private var registration: Registration?

    func register(
        _ operation: UploadInputInspectionOperation,
        for token: Token
    ) async {
        let previousOperation = registration?.operation
        registration = Registration(
            token: token,
            operation: operation
        )
        await previousOperation?.cancel()
    }

    @discardableResult
    func claimCompletion(for token: Token) async -> Bool {
        guard registration?.token == token else { return false }
        let operation = registration?.operation
        registration = nil
        return await operation?.complete() ?? false
    }

    @discardableResult
    func cancel(for token: Token) async -> Bool {
        guard registration?.token == token else { return false }
        let operation = registration?.operation
        registration = nil
        await operation?.cancel()
        return operation != nil
    }
}

protocol UploadInputInspector: Sendable {
    func inspect(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome
}

extension UploadInputInspector {
    @discardableResult
    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) -> UploadInputInspectionOperation {
        let operation = UploadInputInspectionOperation()
        Task {
            let outcome = await inspect(
                sourceInput: sourceInput,
                maximumResolution: maximumResolution,
                operation: operation
            )
            guard await operation.complete() else { return }
            completionHandler(outcome.result, outcome.duration, outcome.error)
        }
        return operation
    }
}

struct UploadInputInspectionError: Error {

    static let inspectionFailure = UploadInputInspectionError()

}

final class AVFoundationUploadInputInspector: UploadInputInspector {

    static let shared = AVFoundationUploadInputInspector()

    func inspect(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome {
        do {
            let videoTracks = try await sourceInput.loadTracks(withMediaType: .video)
            guard !(await operation.isCancelled) else {
                return cancelledOutcome()
            }
            let audioTracks = try? await sourceInput.loadTracks(withMediaType: .audio)
            guard !(await operation.isCancelled) else {
                return cancelledOutcome()
            }
            return await inspect(
                sourceInput: sourceInput,
                videoTracks: videoTracks,
                audioTracks: audioTracks,
                maximumResolution: maximumResolution,
                operation: operation
            )
        } catch {
            return UploadInputInspectionOutcome(
                result: nil,
                duration: .zero,
                error: UploadInputInspectionError.inspectionFailure
            )
        }
    }

    private func inspect(
        sourceInput: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome {
        let audioMetadata = await loadAudioMetadata(
            audioTracks,
            operation: operation
        )
        guard !(await operation.isCancelled) else {
            return cancelledOutcome()
        }
        switch videoTracks.count {
        case 0:
            let metadataResult = AVFoundationUploadInputMetadataReader.inspect(
                videoTracks: [],
                audioTracks: audioMetadata
            )
            return UploadInputInspectionOutcome(
                result: UploadInputFormatInspectionResult(
                    mediaFacts: metadataResult.mediaFacts,
                    metadata: metadataResult.metadata
                ),
                duration: .zero,
                error: nil
            )
        case 1:
            return await inspectSingleVideoTrack(
                sourceInput: sourceInput,
                videoTrack: videoTracks[0],
                audioTracks: audioTracks,
                audioMetadata: audioMetadata,
                maximumResolution: maximumResolution,
                operation: operation
            )
        default:
            return UploadInputInspectionOutcome(
                result: makeVideoInspectionFailureResult(
                    videoTrackCount: videoTracks.count,
                    audioMetadata: audioMetadata
                ),
                duration: .zero,
                error: UploadInputInspectionError.inspectionFailure
            )
        }
    }

    private func inspectSingleVideoTrack(
        sourceInput: AVAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack]?,
        audioMetadata: [AVFoundationAudioTrackMetadata]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome {
        let sourceInputDuration: CMTime
        do {
            sourceInputDuration = try await sourceInput.load(.duration)
        } catch {
            return UploadInputInspectionOutcome(
                result: nil,
                duration: .zero,
                error: UploadInputInspectionError.inspectionFailure
            )
        }

        do {
                async let formatDescriptions = videoTrack.load(.formatDescriptions)
                async let preferredTransform = videoTrack.load(.preferredTransform)
                async let nominalFrameRate = videoTrack.load(.nominalFrameRate)
                async let estimatedDataRate = videoTrack.load(.estimatedDataRate)
                async let segments = videoTrack.load(.segments)
                let loadedMetadata = try await (
                    formatDescriptions,
                    preferredTransform,
                    nominalFrameRate,
                    estimatedDataRate,
                    segments
                )
                guard !(await operation.isCancelled) else {
                    return cancelledOutcome(duration: sourceInputDuration)
                }
                guard let formatDescription = loadedMetadata.0.first else {
                    throw UploadInputInspectionError.inspectionFailure
                }

                let metadataResult = AVFoundationUploadInputMetadataReader.inspect(
                    videoTracks: [
                        AVFoundationVideoTrackMetadata(
                            formatDescriptions: loadedMetadata.0,
                            preferredTransform: loadedMetadata.1,
                            nominalFrameRate: loadedMetadata.2,
                            estimatedDataRate: loadedMetadata.3,
                            segments: loadedMetadata.4.map {
                                AVFoundationVideoTrackSegmentMetadata(
                                    timeMapping: $0.timeMapping,
                                    isEmpty: $0.isEmpty
                                )
                            }
                        )
                    ],
                    audioTracks: audioMetadata
                )
                var mediaFacts = metadataResult.mediaFacts
                let sampleFacts = await AVFoundationUploadInputSampleReader.inspect(
                    asset: sourceInput,
                    videoTrack: videoTrack,
                    codec: mediaFacts.videoCodec,
                    operation: operation
                )
                guard !(await operation.isCancelled) else {
                    return cancelledOutcome(duration: sourceInputDuration)
                }
                mediaFacts.mergeGOPFacts(from: sampleFacts)

                let timelineFacts = await StandardInputTimelineInspector.inspect(
                    asset: sourceInput,
                    videoTrack: videoTrack,
                    audioTrack: audioTracks?.first,
                    duration: sourceInputDuration,
                    operation: operation
                )
                guard !(await operation.isCancelled) else {
                    return cancelledOutcome(duration: sourceInputDuration)
                }

                let videoDimensions = CMVideoFormatDescriptionGetDimensions(
                    formatDescription
                )
                let nonStandardReasons = self.legacyNonStandardReasons(
                    formatDescription: formatDescription,
                    videoDimensions: videoDimensions,
                    frameRate: loadedMetadata.2,
                    estimatedBitrate: loadedMetadata.3
                )

                return UploadInputInspectionOutcome(
                    result: UploadInputFormatInspectionResult(
                        nonStandardInputReasons: nonStandardReasons,
                        mediaFacts: mediaFacts,
                        metadata: metadataResult.metadata,
                        timelineFacts: timelineFacts,
                        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails(
                            maximumDesiredResolutionPreset: maximumResolution,
                            recordedResolution: videoDimensions
                        )
                    ),
                    duration: sourceInputDuration,
                    error: nil
                )
        } catch {
            guard !(await operation.isCancelled) else {
                return cancelledOutcome(duration: sourceInputDuration)
            }
            return UploadInputInspectionOutcome(
                result: makeVideoInspectionFailureResult(
                        videoTrackCount: 1,
                        audioMetadata: audioMetadata
                    ),
                duration: sourceInputDuration,
                error: UploadInputInspectionError.inspectionFailure
            )
        }
    }

    func makeVideoInspectionFailureResult(
        videoTrackCount: Int,
        audioMetadata: [AVFoundationAudioTrackMetadata]?
    ) -> UploadInputFormatInspectionResult {
        let audioResult = AVFoundationUploadInputMetadataReader.inspect(
            videoTracks: [],
            audioTracks: audioMetadata
        )
        var metadata = audioResult.metadata
        metadata.videoTrackCount = videoTrackCount
        return UploadInputFormatInspectionResult(
            mediaFacts: audioResult.mediaFacts,
            metadata: metadata
        )
    }

    private func loadAudioMetadata(
        _ tracks: [AVAssetTrack]?,
        operation: UploadInputInspectionOperation
    ) async -> [AVFoundationAudioTrackMetadata]? {
        guard let tracks else {
            return nil
        }
        var metadata: [AVFoundationAudioTrackMetadata] = []
        for track in tracks {
            guard !(await operation.isCancelled) else { return nil }
            guard let descriptions = try? await track.load(.formatDescriptions) else {
                return nil
            }
            metadata.append(
                AVFoundationAudioTrackMetadata(formatDescriptions: descriptions)
            )
        }
        return metadata
    }

    private func cancelledOutcome(duration: CMTime = .zero) -> UploadInputInspectionOutcome {
        UploadInputInspectionOutcome(
            result: nil,
            duration: duration,
            error: CancellationError()
        )
    }

    private func legacyNonStandardReasons(
        formatDescription: CMFormatDescription,
        videoDimensions: CMVideoDimensions,
        frameRate: Float,
        estimatedBitrate: Float
    ) -> [UploadInputFormatInspectionResult.NonstandardInputReason] {
        var reasons: [UploadInputFormatInspectionResult.NonstandardInputReason] = []
        let maximumDimension = max(videoDimensions.width, videoDimensions.height)

        if maximumDimension > 3840 {
            reasons.append(.videoResolution)
        }
        if formatDescription.mediaSubType.rawValue
            != CMFormatDescription.MediaSubType.h264.rawValue {
            reasons.append(.videoCodec)
        }
        if frameRate > (maximumDimension > 1920 ? 60.0 : 120.0) {
            reasons.append(.videoFrameRate)
        }
        if estimatedBitrate > (maximumDimension > 1920 ? 40_000_000 : 16_000_000) {
            reasons.append(.videoBitrate)
        }

        return reasons
    }
}
