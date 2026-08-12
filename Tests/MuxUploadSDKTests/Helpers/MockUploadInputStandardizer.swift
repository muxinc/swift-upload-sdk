//
//  MockUploadInputStandardizer.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

final class MockUploadInputStandardizer: UploadInputStandardizing {
    private(set) var standardizeCallCount = 0
    private(set) var acknowledgeCompletionCallCount = 0
    private(set) var cancelCallCount = 0

    let error: Error

    init(error: Error = StandardizationError.conversionFailure) {
        self.error = error
    }

    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL,
        completion: @escaping (AVURLAsset, AVAsset?, Error?) -> ()
    ) {
        standardizeCallCount += 1
        completion(sourceAsset, nil, error)
    }

    func cancel(id: String) {
        cancelCallCount += 1
    }

    func acknowledgeCompletion(id: String) {
        acknowledgeCompletionCallCount += 1
    }
}
