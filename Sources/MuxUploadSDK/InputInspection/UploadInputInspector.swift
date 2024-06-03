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
        // TODO: Eventually load audio tracks too
        if #available(iOS 15, *) {
            sourceInput.loadTracks(
                withMediaType: .video
            ) { tracks, error in
                if error != nil {
                    completionHandler(
                        nil, 
                        CMTime.zero,
                        UploadInputInspectionError.inspectionFailure
                    )
                    return
                }

                if let tracks {
                    self.inspect(
                        sourceInput: sourceInput,
                        tracks: tracks,
                        maximumResolution: maximumResolution,
                        completionHandler: completionHandler
                    )
                }
            }
        } else {
            sourceInput.loadValuesAsynchronously(
                forKeys: [
                    "tracks"
                ]
            ) {
                // Non-blocking if "tracks" is already loaded
                let tracks = sourceInput.tracks(
                    withMediaType: .video
                )

                self.inspect(
                    sourceInput: sourceInput,
                    tracks: tracks,
                    maximumResolution: maximumResolution,
                    completionHandler: completionHandler
                )
            }
        }
    }

    func inspect(
        sourceInput: AVAsset,
        tracks: [AVAssetTrack],
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) {
        switch tracks.count {
        case 0:
            // Nothing to inspect, therefore nothing to standardize
            // declare as already standard
            completionHandler(
                UploadInputFormatInspectionResult(),
                CMTime.zero,
                nil
            )
        case 1:

            sourceInput.loadValuesAsynchronously(
                forKeys: [
                    "duration"
                ]
            ) {
                let sourceInputDuration = sourceInput.duration
                if let track = tracks.first {
                    track.loadValuesAsynchronously(
                        forKeys: [
                            "formatDescriptions",
                            "nominalFrameRate"
                        ]
                    ) {
                        guard let formatDescriptions = track.formatDescriptions as? [CMFormatDescription] else {
                            completionHandler(
                                nil,
                                sourceInputDuration,
                                UploadInputInspectionError.inspectionFailure
                            )
                            return
                        }

                        guard let formatDescription = formatDescriptions.first else {
                            completionHandler(
                                nil,
                                sourceInputDuration,
                                UploadInputInspectionError.inspectionFailure
                            )
                            return
                        }

                        var nonStandardReasons: [UploadInputFormatInspectionResult.NonstandardInputReason] = []

                        let videoDimensions = CMVideoFormatDescriptionGetDimensions(
                            formatDescription
                        )

                        if max(videoDimensions.width, videoDimensions.height) > 3840 {
                            nonStandardReasons.append(.videoResolution)
                        }

                        let rawVideoCodecType = formatDescription.mediaSubType.rawValue

                        let rawStandardCodecType = CMFormatDescription.MediaSubType.h264.rawValue

                        if rawVideoCodecType != rawStandardCodecType {
                            nonStandardReasons.append(.videoCodec)
                        }

                        let frameRate = track.nominalFrameRate

                        if max(videoDimensions.width, videoDimensions.height) > 1920 {
                            if frameRate > 60.0 {
                                nonStandardReasons.append(.videoFrameRate)
                            }
                        } else {
                            if frameRate > 120.0 {
                                nonStandardReasons.append(.videoFrameRate)
                            }
                        }
                        completionHandler(
                            UploadInputFormatInspectionResult(
                                nonStandardInputReasons: nonStandardReasons,
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
        default:
            // Inspection fails for multi-video track inputs
            // for the time being
            completionHandler(
                nil,
                CMTime.zero,
                UploadInputInspectionError.inspectionFailure
            )
        }
    }
}
