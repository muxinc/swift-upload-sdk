//
//  UploadInputInspector.swift
//  

import AVFoundation
import CoreMedia
import Foundation

protocol UploadInputInspector {
    func performInspection(
        sourceInput: AVAsset,
        completionHandler: @escaping (UploadInputFormatInspectionResult) -> ()
    )
}

class AVFoundationUploadInputInspector: UploadInputInspector {

    static let shared = AVFoundationUploadInputInspector()

    func performInspection(
        sourceInput: AVAsset,
        completionHandler: @escaping (UploadInputFormatInspectionResult) -> ()
    ) {
        // TODO: Eventually load audio tracks too
        if #available(iOS 15, *) {
            sourceInput.loadTracks(
                withMediaType: .video
            ) { tracks, error in
                if error != nil {
                    completionHandler(.inspectionFailure)
                    return
                }

                if let tracks {
                    self.inspect(
                        tracks: tracks,
                        completionHandler: completionHandler
                    )
                }
            }
        } else {
            sourceInput.loadValuesAsynchronously(
                forKeys: ["tracks"]
            ) {
                // Non-blocking if "tracks" is already loaded
                let tracks = sourceInput.tracks(
                    withMediaType: .video
                )
                self.inspect(
                    tracks: tracks,
                    completionHandler: completionHandler
                )
            }
        }

    }

    func inspect(
        tracks: [AVAssetTrack],
        completionHandler: @escaping (UploadInputFormatInspectionResult) -> ()
    ) {
        switch tracks.count {
        case 0:
            // Nothing to inspect, therefore nothing to standardize
            // declare as already standard
            completionHandler(.standard)
        case 1:
            if let track = tracks.first {
                track.loadValuesAsynchronously(
                    forKeys: [
                        "formatDescriptions",
                        "nominalFrameRate"
                    ]
                ) {
                    guard let formatDescriptions = track.formatDescriptions as? [CMFormatDescription] else {
                        completionHandler(.inspectionFailure)
                        return
                    }

                    guard let formatDescription = formatDescriptions.first else {
                        completionHandler(.inspectionFailure)
                        return
                    }

                    var nonStandardReasons: [UploadInputFormatInspectionResult.NonstandardInputReason] = []

                    let videoDimensions = CMVideoFormatDescriptionGetDimensions(
                        formatDescription
                    )

                    if max(videoDimensions.width, videoDimensions.height) > 1920 {
                        nonStandardReasons.append(.videoResolution)
                    }

                    let videoCodecType = formatDescription.mediaSubType

                    let standard = CMFormatDescription.MediaSubType.h264

                    if videoCodecType != standard {
                        nonStandardReasons.append(.videoCodec)
                    }

                    let frameRate = track.nominalFrameRate
                    if frameRate > 120.0 {
                        nonStandardReasons.append(.videoFrameRate)
                    }

                    if nonStandardReasons.isEmpty {
                        completionHandler(.standard)
                    } else {
                        completionHandler(.nonstandard(nonStandardReasons))
                    }

                }
            }
        default:
            // Inspection fails for multi-video track inputs
            // for the time being
            completionHandler(.inspectionFailure)
        }
    }
}
