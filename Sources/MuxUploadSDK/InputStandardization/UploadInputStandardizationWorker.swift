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

class UploadInputStandardizationWorker {

    var sourceInput: AVAsset?

    var standardizedInput: AVAsset?

    func standardize(
        sourceAsset: AVAsset,
        maximumResolution: UploadOptions.InputStandardization.MaximumResolution,
        outputURL: URL,
        completion: @escaping (AVAsset, AVAsset?, URL?, Bool) -> ()
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
            completion(sourceAsset, nil, nil, false)
            return
        }

        guard let exportSession = AVAssetExportSession(
            asset: sourceAsset,
            presetName: exportPreset
        ) else {
            // TODO: Use VideoToolbox if export session fails to initialize
            completion(sourceAsset, nil, nil, false)
            return
        }

        exportSession.outputFileType = .mp4
        exportSession.outputURL = outputURL

        // TODO: Use Swift Concurrency
        exportSession.exportAsynchronously {
            if let exportError = exportSession.error {
                completion(sourceAsset, nil, nil, false)
            } else if let standardizedAssetURL = exportSession.outputURL {
                let standardizedAsset = AVAsset(url: standardizedAssetURL)
                completion(sourceAsset, standardizedAsset, outputURL, true)
            } else {
                completion(sourceAsset, nil, nil, false)
            }
        }
    }
}
