//
//  UploadInputStandardizationWorker.swift
//  

import AVFoundation
import Foundation

protocol Standardizable { }

extension AVAsset: Standardizable { }

enum StandardizationResult {
    case success(standardizedAsset: AVAsset)
    case failure(error: Error)
}

enum StandardizationStrategy {
    // Prefer using export session whenever possible
    case exportSession
}

struct StandardizationError: Error {
    var localizedDescription: String

    static var missingExportPreset = StandardizationError(
        localizedDescription: "Missing export session preset"
    )

    static var exportSessionInitializationFailure = StandardizationError(
        localizedDescription: "Export session failed to initialize"
    )

    static var standardizedAssetExportFailure = StandardizationError(
        localizedDescription: "Failed to export standardized asset"
    )

    static var standardizedAssetWriteFailure = StandardizationError(
        localizedDescription: "Failed to write standardized asset to disk"
    )
}

class UploadInputStandardizationWorker {

    var sourceInput: AVAsset?

    var standardizedInput: AVAsset?

    func standardize(
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    ) {

        let availableExportPresets = AVAssetExportSession.allExportPresets()

        let exportPreset: String

        switch rescalingDetails.maximumDesiredResolutionPreset {
        case .default:
            exportPreset = AVAssetExportPreset1920x1080
        case .preset1280x720:
            exportPreset = AVAssetExportPreset1280x720
        case .preset1920x1080:
            exportPreset = AVAssetExportPreset1920x1080
        case .preset3840x2160:
            exportPreset = AVAssetExportPreset3840x2160
        }

        guard availableExportPresets.contains(where: {
            $0 == exportPreset
        }) else {
            // TODO: Use VideoToolbox if export preset unavailable
            completion(sourceAsset, nil, StandardizationError.missingExportPreset)
            return
        }

        guard let exportSession = AVAssetExportSession(
            asset: sourceAsset,
            presetName: exportPreset
        ) else {
            // TODO: Use VideoToolbox if export session fails to initialize
            completion(sourceAsset, nil, StandardizationError.exportSessionInitializationFailure)
            return
        }

        exportSession.outputFileType = .mp4
        exportSession.outputURL = outputURL

        // TODO: Use Swift Concurrency
        exportSession.exportAsynchronously {
            if let exportError = exportSession.error {
                completion(sourceAsset, nil, exportError)
            } else if let standardizedAssetURL = exportSession.outputURL {
                let standardizedAsset = AVAsset(url: standardizedAssetURL)
                completion(sourceAsset, standardizedAsset, nil)
            } else {
                completion(sourceAsset, nil, StandardizationError.standardizedAssetExportFailure)
            }
        }
    }
}
