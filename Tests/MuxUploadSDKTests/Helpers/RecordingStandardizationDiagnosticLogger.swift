//
//  RecordingStandardizationDiagnosticLogger.swift
//

@testable import MuxUploadSDK

actor RecordingStandardizationDiagnosticLogger: StandardizationDiagnosticLogging {
    private var recordedDiagnostics: [StandardizationDiagnostic] = []

    func log(_ diagnostic: StandardizationDiagnostic) {
        recordedDiagnostics.append(diagnostic)
    }

    func messages() -> [String] {
        recordedDiagnostics.map(\.message)
    }
}
