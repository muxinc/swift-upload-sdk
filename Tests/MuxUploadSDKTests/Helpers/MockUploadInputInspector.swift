//
//  MockUploadInputInspector.swift
//

import AVFoundation
import Foundation

@testable import MuxUploadSDK

actor MockUploadInputInspector: UploadInputInspector {

    static let alwaysStandard: MockUploadInputInspector = MockUploadInputInspector()

    static let alwaysFailing: MockUploadInputInspector = MockUploadInputInspector(
        mockInspectionResult: UploadInputFormatInspectionResult(
            nonStandardInputReasons: [],
            rescalingDetails: .init()
        ),
        mockInspectionError: UploadInputInspectionError.inspectionFailure
    )

    private var outcomes: [UploadInputInspectionOutcome]
    private let shouldDeferCompletion: Bool
    private var operation: UploadInputInspectionOperation?
    private var continuation: CheckedContinuation<UploadInputInspectionOutcome, Never>?

    init(
        mockInspectionResult: UploadInputFormatInspectionResult = UploadInputFormatInspectionResult(
            nonStandardInputReasons: [],
            rescalingDetails: .init()
        ),
        mockInspectionError: Error? = nil,
        duration: CMTime = .zero,
        shouldDeferCompletion: Bool = false,
        subsequentResults: [UploadInputFormatInspectionResult] = []
    ) {
        self.outcomes = [
            UploadInputInspectionOutcome(
                result: mockInspectionResult,
                duration: duration,
                error: mockInspectionError
            )
        ] + subsequentResults.map {
            UploadInputInspectionOutcome(result: $0, duration: duration, error: nil)
        }
        self.shouldDeferCompletion = shouldDeferCompletion
    }

    func inspect(
        sourceInput: AVAsset,
        maximumResolution: DirectUploadOptions.InputStandardization.MaximumResolution,
        operation: UploadInputInspectionOperation
    ) async -> UploadInputInspectionOutcome {
        if shouldDeferCompletion {
            self.operation = operation
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } else {
            return nextOutcome()
        }
    }

    func completeDeferredInspection() {
        operation = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: nextOutcome())
    }

    func currentOperation() -> UploadInputInspectionOperation? {
        operation
    }

    private func nextOutcome() -> UploadInputInspectionOutcome {
        guard outcomes.count > 1 else { return outcomes[0] }
        return outcomes.removeFirst()
    }

}
