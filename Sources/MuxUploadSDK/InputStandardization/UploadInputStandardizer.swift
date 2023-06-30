//
//  UploadInputStandardizer.swift
//  

import AVFoundation
import Foundation

class UploadInputStandardizer {
    var workers: [String: UploadInputStandardizationWorker] = [:]

    var fileManager: FileManager = .default

    func standardize(
        id: String,
        sourceAsset: AVAsset,
        completion: @escaping (AVAsset, AVAsset?, URL?, Bool) -> ()
    ) {
        let worker = UploadInputStandardizationWorker()

        // TODO: inject Date() for testing purposes
        let outputFileName = "upload-\(Date().timeIntervalSince1970)"

        let temporaryDirectory = fileManager.temporaryDirectory
        let temporaryOutputURL = URL(
            fileURLWithPath: outputFileName,
            relativeTo: temporaryDirectory
        )

        worker.standardize(
            sourceAsset: sourceAsset,
            outputURL: temporaryOutputURL,
            completion: completion
        )
        workers[id] = worker
    }
}
