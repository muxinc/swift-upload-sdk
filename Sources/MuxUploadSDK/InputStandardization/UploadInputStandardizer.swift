//
//  UploadInputStandardizer.swift
//  

import AVFoundation
import Foundation

protocol UploadInputStandardizing: Sendable {
    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset

    func cancel(id: String) async
}

actor UploadInputStandardizer: UploadInputStandardizing {
    private struct Entry {
        let operationID: UUID
        let worker: UploadInputStandardizationWorking
    }

    private let workerFactory: @Sendable () -> UploadInputStandardizationWorking
    private var entries: [String: Entry] = [:]

    init(
        workerFactory: @escaping @Sendable () -> UploadInputStandardizationWorking = {
            UploadInputStandardizationWorker()
        }
    ) {
        self.workerFactory = workerFactory
    }

    func standardize(
        id: String,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        outputURL: URL
    ) async throws -> AVURLAsset {
        let worker = workerFactory()
        let operationID = UUID()
        let previousWorker = entries.updateValue(
            Entry(operationID: operationID, worker: worker),
            forKey: id
        )?.worker
        await previousWorker?.cancel()

        do {
            let result = try await worker.standardize(
                sourceAsset: sourceAsset,
                rescalingDetails: rescalingDetails,
                outputURL: outputURL
            )
            removeWorker(id: id, operationID: operationID)
            return result
        } catch {
            removeWorker(id: id, operationID: operationID)
            throw error
        }
    }

    func cancel(id: String) async {
        let worker = entries.removeValue(forKey: id)?.worker
        await worker?.cancel()
    }

    func hasWorker(id: String) -> Bool {
        entries[id] != nil
    }

    private func removeWorker(id: String, operationID: UUID) {
        guard entries[id]?.operationID == operationID else { return }
        entries[id] = nil
    }
}
