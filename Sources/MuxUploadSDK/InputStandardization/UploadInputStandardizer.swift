//
//  UploadInputStandardizer.swift
//  

import AVFoundation
import Foundation

protocol UploadInputStandardizing {
    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    )

    func acknowledgeCompletion(id: String)
}

class UploadInputStandardizer: UploadInputStandardizing {
    var workers: [String: UploadInputStandardizationWorker] = [:]

    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    ) {
        let worker = UploadInputStandardizationWorker()
        workers[id] = worker

        worker.standardize(
            sourceAsset: sourceAsset,
            rescalingDetails: rescalingDetails,
            outputURL: outputURL,
            completion: completion
        )
    }

    // Storing the worker might not be necessary if an
    // alternative reference is in place outside the
    // stack frame
    func acknowledgeCompletion(
        id: String
    ) {
        workers[id] = nil
    }
}
