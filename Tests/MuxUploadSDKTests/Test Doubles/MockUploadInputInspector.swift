//
//  MockUploadInputInspector.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

class MockUploadInputInspector: UploadInputInspector {

    static let alwaysStandard: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: .standard
    )

    static let alwaysFailing: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: .inspectionFailure
    )

    var mockInspectionResult: UploadInputFormatInspectionResult

    init() {
        self.mockInspectionResult = .standard
    }

    init(
        mockInspectionResult: UploadInputFormatInspectionResult
    ) {
        self.mockInspectionResult = mockInspectionResult
    }

    func performInspection(
        sourceInput: AVAsset,
        completionHandler: @escaping (UploadInputFormatInspectionResult) -> ()
    ) {
        completionHandler(mockInspectionResult)
    }

}
