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
        let conversion: StandardInputConversion?
        let outputURL: URL?
    }

    private(set) var standardizeCallCount = 0
    private(set) var cancelCallCount = 0
    private var receivedConversion: StandardInputConversion?
    private var receivedOutputURL: URL?

    let error: Error?
    let resultURL: URL?

    init(
        error: Error? = StandardizationError.conversionFailure,
        resultURL: URL? = nil
    ) {
        self.error = error
        self.resultURL = resultURL
    }

    func standardize(
        id: String,
        token: UploadInputStandardizationToken,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        conversion: StandardInputConversion,
        outputURL: URL
    ) async throws -> AVURLAsset {
        standardizeCallCount += 1
        receivedConversion = conversion
        receivedOutputURL = outputURL
        if let error { throw error }
        return AVURLAsset(url: resultURL ?? outputURL)
    }

    func cancel(id: String, token: UploadInputStandardizationToken) {
        cancelCallCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            standardizeCallCount: standardizeCallCount,
            cancelCallCount: cancelCallCount,
            conversion: receivedConversion,
            outputURL: receivedOutputURL
        )
    }
}
