//
//  UploadInputInspector.swift
//  

import AVFoundation
import CoreMedia
import Foundation

typealias UploadInputInspectionCompletionHandler = (UploadInputFormatInspectionResult?, CMTime, Error?) -> ()

final class UploadInputInspectionOperation {
    private enum State {
        case active
        case cancelled
        case completed
    }

    private let lock = NSLock()
    private let completionHandler: UploadInputInspectionCompletionHandler
    private var state: State = .active
    private var assetReader: AVAssetReader?

    init(completionHandler: @escaping UploadInputInspectionCompletionHandler) {
        self.completionHandler = completionHandler
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func register(assetReader: AVAssetReader) -> Bool {
        lock.lock()
        let isActive = state == .active
        if isActive {
            self.assetReader = assetReader
        }
        lock.unlock()

        if !isActive {
            assetReader.cancelReading()
        }
        return isActive
    }

    func cancel() {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .cancelled
        let assetReader = self.assetReader
        self.assetReader = nil
        lock.unlock()

        assetReader?.cancelReading()
    }

    func complete(
        _ result: UploadInputFormatInspectionResult?,
        duration: CMTime,
        error: Error?
    ) {
        lock.lock()
        guard state == .active else {
            lock.unlock()
            return
        }
        state = .completed
        assetReader = nil
        lock.unlock()

        completionHandler(result, duration, error)
    }
}

final class UploadInputInspectionOperationRegistry: @unchecked Sendable {
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

    private let lock = NSLock()
    private var registration: Registration?

    func register(
        _ operation: UploadInputInspectionOperation,
        for token: Token
    ) {
        lock.lock()
        let previousOperation = registration?.operation
        registration = Registration(
            token: token,
            operation: operation
        )
        lock.unlock()

        previousOperation?.cancel()
    }

    @discardableResult
    func claimCompletion(for token: Token) -> Bool {
        lock.lock()
        guard registration?.token == token else {
            lock.unlock()
            return false
        }
        registration = nil
        lock.unlock()
        return true
    }

    @discardableResult
    func cancel(for token: Token) -> Bool {
        lock.lock()
        guard registration?.token == token else {
            lock.unlock()
            return false
        }
        let operation = registration?.operation
        registration = nil
        lock.unlock()

        operation?.cancel()
        return operation != nil
    }
}

protocol UploadInputInspector {
    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    )
}

extension UploadInputInspector {
    @discardableResult
    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) -> UploadInputInspectionOperation {
        let operation = UploadInputInspectionOperation(
            completionHandler: completionHandler
        )
        performInspection(
            sourceInput: sourceInput,
            maximumResolution: maximumResolution,
            operation: operation
        )
        return operation
    }
}

struct UploadInputInspectionError: Error {

    static let inspectionFailure = UploadInputInspectionError()

}

class AVFoundationUploadInputInspector: UploadInputInspector {

    static let shared = AVFoundationUploadInputInspector()

    // FIXME: Trying to avoid the callback pyramid of doom
    // here, newer AVAsset APIs use Concurrency
    // but Concurrency itself has very primitive
    // task sequencing. Replace with async AVAsset
    // methods.
    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) {
        sourceInput.loadTracks(
            withMediaType: .video
        ) { videoTracks, videoError in
            guard !operation.isCancelled else { return }
            guard videoError == nil, let videoTracks else {
                operation.complete(
                    nil,
                    duration: CMTime.zero,
                    error: UploadInputInspectionError.inspectionFailure
                )
                return
            }

            sourceInput.loadTracks(
                withMediaType: .audio
            ) { audioTracks, audioError in
                guard !operation.isCancelled else { return }
                self.inspect(
                    sourceInput: sourceInput,
                    videoTracks: videoTracks,
                    audioTracks: audioError == nil ? audioTracks : nil,
                    maximumResolution: maximumResolution,
                    operation: operation
                )
            }
        }
    }

    func inspect(
        sourceInput: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) {
        loadAudioMetadata(audioTracks, operation: operation) { audioMetadata in
            guard !operation.isCancelled else { return }
            switch videoTracks.count {
            case 0:
                let metadataResult = AVFoundationUploadInputMetadataReader.inspect(
                    videoTracks: [],
                    audioTracks: audioMetadata
                )
                operation.complete(
                    UploadInputFormatInspectionResult(
                        mediaFacts: metadataResult.mediaFacts,
                        metadata: metadataResult.metadata
                    ),
                    duration: CMTime.zero,
                    error: nil
                )
            case 1:
                self.inspectSingleVideoTrack(
                    sourceInput: sourceInput,
                    videoTrack: videoTracks[0],
                    audioMetadata: audioMetadata,
                    maximumResolution: maximumResolution,
                    operation: operation
                )
            default:
                operation.complete(
                    self.makeVideoInspectionFailureResult(
                        videoTrackCount: videoTracks.count,
                        audioMetadata: audioMetadata
                    ),
                    duration: CMTime.zero,
                    error: UploadInputInspectionError.inspectionFailure
                )
            }
        }
    }

    private func inspectSingleVideoTrack(
        sourceInput: AVAsset,
        videoTrack: AVAssetTrack,
        audioMetadata: [AVFoundationAudioTrackMetadata]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) {
        sourceInput.loadValuesAsynchronously(forKeys: ["duration"]) {
            guard !operation.isCancelled else { return }
            let sourceInputDuration = sourceInput.duration
            videoTrack.loadValuesAsynchronously(
                forKeys: [
                    "formatDescriptions",
                    "preferredTransform",
                    "nominalFrameRate",
                    "estimatedDataRate"
                ]
            ) {
                guard !operation.isCancelled else { return }
                guard let formatDescriptions = videoTrack.formatDescriptions
                    as? [CMFormatDescription],
                      let formatDescription = formatDescriptions.first else {
                    operation.complete(
                        self.makeVideoInspectionFailureResult(
                            videoTrackCount: 1,
                            audioMetadata: audioMetadata
                        ),
                        duration: sourceInputDuration,
                        error: UploadInputInspectionError.inspectionFailure
                    )
                    return
                }

                let metadataResult = AVFoundationUploadInputMetadataReader.inspect(
                    videoTracks: [
                        AVFoundationVideoTrackMetadata(
                            formatDescriptions: formatDescriptions,
                            preferredTransform: videoTrack.preferredTransform,
                            nominalFrameRate: videoTrack.nominalFrameRate,
                            estimatedDataRate: videoTrack.estimatedDataRate
                        )
                    ],
                    audioTracks: audioMetadata
                )
                var mediaFacts = metadataResult.mediaFacts
                let sampleFacts = AVFoundationUploadInputSampleReader.inspect(
                    asset: sourceInput,
                    videoTrack: videoTrack,
                    codec: mediaFacts.videoCodec,
                    operation: operation
                )
                guard !operation.isCancelled else { return }
                mediaFacts.mergeGOPFacts(from: sampleFacts)

                let videoDimensions = CMVideoFormatDescriptionGetDimensions(
                    formatDescription
                )
                let nonStandardReasons = self.legacyNonStandardReasons(
                    formatDescription: formatDescription,
                    videoDimensions: videoDimensions,
                    frameRate: videoTrack.nominalFrameRate,
                    estimatedBitrate: videoTrack.estimatedDataRate
                )

                operation.complete(
                    UploadInputFormatInspectionResult(
                        nonStandardInputReasons: nonStandardReasons,
                        mediaFacts: mediaFacts,
                        metadata: metadataResult.metadata,
                        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails(
                            maximumDesiredResolutionPreset: maximumResolution,
                            recordedResolution: videoDimensions
                        )
                    ),
                    duration: sourceInputDuration,
                    error: nil
                )
            }
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
        operation: UploadInputInspectionOperation,
        index: Int = 0,
        accumulated: [AVFoundationAudioTrackMetadata] = [],
        completionHandler: @escaping ([AVFoundationAudioTrackMetadata]?) -> Void
    ) {
        guard let tracks else {
            completionHandler(nil)
            return
        }

        guard index < tracks.count else {
            completionHandler(accumulated)
            return
        }

        let track = tracks[index]
        track.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
            guard !operation.isCancelled else { return }
            let formatDescriptions = track.formatDescriptions as? [CMFormatDescription]
                ?? []
            self.loadAudioMetadata(
                tracks,
                operation: operation,
                index: index + 1,
                accumulated: accumulated + [
                    AVFoundationAudioTrackMetadata(
                        formatDescriptions: formatDescriptions
                    )
                ],
                completionHandler: completionHandler
            )
        }
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
