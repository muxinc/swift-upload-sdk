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
}

class UploadInputStandardizationWorker {

    var sourceInput: AVAsset?

    var standardizedInput: AVAsset?

    func standardize(
        sourceAsset: AVAsset,
        maximumResolution: UploadOptions.InputStandardization.MaximumResolution,
        outputURL: URL,
        completion: @escaping (AVAsset, AVAsset?, Error?) -> ()
    ) {

        let availableExportPresets = AVAssetExportSession.allExportPresets()

        let exportPreset: String
        if maximumResolution == .preset1280x720 {
            exportPreset = AVAssetExportPreset1280x720
        } else {
            exportPreset = AVAssetExportPreset1920x1080
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
