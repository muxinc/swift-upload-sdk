//
//  UploadInputStandardizer.swift
//  

import AVFoundation
import Foundation

class UploadInputStandardizer {
    var workers: [String: UploadInputStandardizationWorker] = [:]

    func standardize(
        id: String,
        sourceAsset: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        outputURL: URL,
        completion: @escaping (AVAsset, AVAsset?, Error?) -> ()
    ) {
        let worker = UploadInputStandardizationWorker()

        worker.standardize(
            sourceAsset: sourceAsset,
            maximumResolution: maximumResolution,
            outputURL: outputURL,
            completion: completion
        )
        workers[id] = worker
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
