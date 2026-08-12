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

    func cancel(id: String)

    func acknowledgeCompletion(id: String)
}

class UploadInputStandardizer: UploadInputStandardizing {
    private let lock = NSLock()
    private let workerFactory: () -> UploadInputStandardizationWorking
    private(set) var workers: [String: UploadInputStandardizationWorking] = [:]

    init(
        workerFactory: @escaping () -> UploadInputStandardizationWorking = {
            UploadInputStandardizationWorker()
        }
    ) {
        self.workerFactory = workerFactory
    }

    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    ) {
        let worker = workerFactory()
        lock.lock()
        let previousWorker = workers.updateValue(worker, forKey: id)
        lock.unlock()
        previousWorker?.cancel()

        worker.standardize(
            sourceAsset: sourceAsset,
            rescalingDetails: rescalingDetails,
            outputURL: outputURL,
            completion: completion
        )
    }

    func cancel(id: String) {
        lock.lock()
        let worker = workers.removeValue(forKey: id)
        lock.unlock()
        worker?.cancel()
    }

    func acknowledgeCompletion(
        id: String
    ) {
        lock.lock()
        workers[id] = nil
        lock.unlock()
    }
}
