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
            rescalingDetails: .init()
        ),
        mockInspectionError: UploadInputInspectionError.inspectionFailure
    )

    var mockInspectionError: Error?
    var mockInspectionResult: UploadInputFormatInspectionResult
    var duration: CMTime
    var shouldDeferCompletion = false
    private(set) var operation: UploadInputInspectionOperation?

    init() {
        self.mockInspectionResult = UploadInputFormatInspectionResult(
            nonStandardInputReasons: [],
            rescalingDetails: .init()
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
        operation: UploadInputInspectionOperation
    ) {
        if shouldDeferCompletion {
            self.operation = operation
        } else {
            operation.complete(
                mockInspectionResult,
                duration: duration,
                error: mockInspectionError
            )
        }
    }

    func completeDeferredInspection() {
        operation?.complete(
            mockInspectionResult,
            duration: duration,
            error: mockInspectionError
        )
        operation = nil
    }

}
