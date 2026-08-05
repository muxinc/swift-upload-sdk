//
//  UploadInputInspector.swift
//  

import AVFoundation
import CoreMedia
import Foundation

typealias UploadInputInspectionCompletionHandler = (UploadInputFormatInspectionResult?, CMTime, Error?) -> ()

protocol UploadInputInspector {
    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    )
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
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) {
        sourceInput.loadTracks(
            withMediaType: .video
        ) { videoTracks, videoError in
            guard videoError == nil, let videoTracks else {
                completionHandler(
                    nil,
                    CMTime.zero,
                    UploadInputInspectionError.inspectionFailure
                )
                return
            }

            sourceInput.loadTracks(
                withMediaType: .audio
            ) { audioTracks, audioError in
                self.inspect(
                    sourceInput: sourceInput,
                    videoTracks: videoTracks,
                    audioTracks: audioError == nil ? audioTracks : nil,
                    maximumResolution: maximumResolution,
                    completionHandler: completionHandler
                )
            }
        }
    }

    func inspect(
        sourceInput: AVAsset,
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) {
        loadAudioMetadata(audioTracks) { audioMetadata in
            switch videoTracks.count {
            case 0:
                let metadataResult = AVFoundationUploadInputMetadataReader.inspect(
                    videoTracks: [],
                    audioTracks: audioMetadata
                )
                completionHandler(
                    UploadInputFormatInspectionResult(
                        mediaFacts: metadataResult.mediaFacts,
                        metadata: metadataResult.metadata
                    ),
                    CMTime.zero,
                    nil
                )
            case 1:
                self.inspectSingleVideoTrack(
                    sourceInput: sourceInput,
                    videoTrack: videoTracks[0],
                    audioMetadata: audioMetadata,
                    maximumResolution: maximumResolution,
                    completionHandler: completionHandler
                )
            default:
                let audioResult = AVFoundationUploadInputMetadataReader.inspect(
                    videoTracks: [],
                    audioTracks: audioMetadata
                )
                var metadata = audioResult.metadata
                metadata.videoTrackCount = videoTracks.count
                completionHandler(
                    UploadInputFormatInspectionResult(
                        mediaFacts: audioResult.mediaFacts,
                        metadata: metadata
                    ),
                    CMTime.zero,
                    UploadInputInspectionError.inspectionFailure
                )
            }
        }
    }

    private func inspectSingleVideoTrack(
        sourceInput: AVAsset,
        videoTrack: AVAssetTrack,
        audioMetadata: [AVFoundationAudioTrackMetadata]?,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) {
        sourceInput.loadValuesAsynchronously(forKeys: ["duration"]) {
            let sourceInputDuration = sourceInput.duration
            videoTrack.loadValuesAsynchronously(
                forKeys: [
                    "formatDescriptions",
                    "preferredTransform",
                    "nominalFrameRate",
                    "estimatedDataRate"
                ]
            ) {
                guard let formatDescriptions = videoTrack.formatDescriptions
                    as? [CMFormatDescription],
                      let formatDescription = formatDescriptions.first else {
                    completionHandler(
                        UploadInputFormatInspectionResult(
                            metadata: UploadInputMetadataInspection(
                                videoTrackCount: 1,
                                audioTrackCount: audioMetadata.map {
                                    .known($0.count)
                                } ?? .unknown
                            )
                        ),
                        sourceInputDuration,
                        UploadInputInspectionError.inspectionFailure
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
                let videoDimensions = CMVideoFormatDescriptionGetDimensions(
                    formatDescription
                )
                let nonStandardReasons = self.legacyNonStandardReasons(
                    formatDescription: formatDescription,
                    videoDimensions: videoDimensions,
                    frameRate: videoTrack.nominalFrameRate,
                    estimatedBitrate: videoTrack.estimatedDataRate
                )

                completionHandler(
                    UploadInputFormatInspectionResult(
                        nonStandardInputReasons: nonStandardReasons,
                        mediaFacts: metadataResult.mediaFacts,
                        metadata: metadataResult.metadata,
                        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails(
                            maximumDesiredResolutionPreset: maximumResolution,
                            recordedResolution: videoDimensions
                        )
                    ),
                    sourceInputDuration,
                    nil
                )
            }
        }
    }

    private func loadAudioMetadata(
        _ tracks: [AVAssetTrack]?,
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
            let formatDescriptions = track.formatDescriptions as? [CMFormatDescription]
                ?? []
            self.loadAudioMetadata(
                tracks,
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
