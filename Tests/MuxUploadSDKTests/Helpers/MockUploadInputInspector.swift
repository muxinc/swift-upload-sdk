//
//  MockUploadInputInspector.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

class MockUploadInputInspector: UploadInputInspector {

    static let alwaysStandard: MockUploadInputInspector = MockUploadInputInspector()

    static let alwaysFailing: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: UploadInputFormatInspectionResult(
            nonStandardInputReasons: [],
            maximumResolution: .default
        ),
        mockInspectionError: UploadInputInspectionError.inspectionFailure
    )

    var mockInspectionError: Error?
    var mockInspectionResult: UploadInputFormatInspectionResult
    var duration: CMTime

    init() {
        self.mockInspectionResult = UploadInputFormatInspectionResult(
            nonStandardInputReasons: [],
            maximumResolution: .default
        )
        self.duration = .zero
    }

    init(
        mockInspectionResult: UploadInputFormatInspectionResult,
        mockInspectionError: Error? = nil
    ) {
        self.mockInspectionResult = mockInspectionResult
        self.mockInspectionError = mockInspectionError
        self.duration = .zero
    }

    func performInspection(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        completionHandler: @escaping UploadInputInspectionCompletionHandler
    ) {
        completionHandler(mockInspectionResult, duration, mockInspectionError)
    }

}
