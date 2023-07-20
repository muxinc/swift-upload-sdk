//
//  MockUploadInputInspector.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

class MockUploadInputInspector: UploadInputInspector {

    static let alwaysStandard: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: .standard(duration: .zero)
    )

    static let alwaysFailing: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: .inspectionFailure(duration: .zero)
    )

    var mockInspectionResult: UploadInputFormatInspectionResult

    init() {
        self.mockInspectionResult = .standard(duration: .zero)
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
