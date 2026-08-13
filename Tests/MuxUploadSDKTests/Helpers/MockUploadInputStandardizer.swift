//
//  MockUploadInputStandardizer.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

actor MockUploadInputStandardizer: UploadInputStandardizing {
    struct Snapshot {
        let standardizeCallCount: Int
        let cancelCallCount: Int
    }

    private(set) var standardizeCallCount = 0
    private(set) var cancelCallCount = 0

    let error: Error

    init(error: Error = StandardizationError.conversionFailure) {
        self.error = error
    }

    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset {
        standardizeCallCount += 1
        throw error
    }

    func cancel(id: String) {
        cancelCallCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            standardizeCallCount: standardizeCallCount,
            cancelCallCount: cancelCallCount
        )
    }
}
