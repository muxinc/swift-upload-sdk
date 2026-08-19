//
//  UploadInputStandardizer.swift
//  

import AVFoundation
import Foundation

struct UploadInputStandardizationToken: Equatable, Sendable {
    private let id = UUID()
}

protocol UploadInputStandardizing: Sendable {
    func standardize(
        id: String,
        token: UploadInputStandardizationToken,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        conversion: StandardInputConversion,
        outputURL: URL
    ) async throws -> AVURLAsset

    func cancel(id: String, token: UploadInputStandardizationToken) async
}

actor UploadInputStandardizer: UploadInputStandardizing {
    private struct Entry {
        let token: UploadInputStandardizationToken
        let worker: UploadInputStandardizationWorking
    }

    private let workerFactory: @Sendable (
        UploadInputStandardizationToken
    ) -> UploadInputStandardizationWorking
    private var entries: [String: Entry] = [:]

    init(
        workerFactory: @escaping @Sendable (
            UploadInputStandardizationToken
        ) -> UploadInputStandardizationWorking = { _ in
            UploadInputStandardizationWorker()
        }
    ) {
        self.workerFactory = workerFactory
    }

    func standardize(
        id: String,
        token: UploadInputStandardizationToken,
        sourceAsset: AVURLAsset,
        rescalingDetails: UploadInputFormatInspectionResult.RescalingDetails,
        conversion: StandardInputConversion,
        outputURL: URL
    ) async throws -> AVURLAsset {
        let worker = workerFactory(token)
        let previousWorker = entries.updateValue(
            Entry(token: token, worker: worker),
            forKey: id
        )?.worker
        await previousWorker?.cancel()

        do {
            let result = try await worker.standardize(
                sourceAsset: sourceAsset,
                rescalingDetails: rescalingDetails,
                conversion: conversion,
                outputURL: outputURL
            )
            removeWorker(id: id, token: token)
            return result
        } catch {
            removeWorker(id: id, token: token)
            throw error
        }
    }

    func cancel(id: String, token: UploadInputStandardizationToken) async {
        guard entries[id]?.token == token else { return }
        let worker = entries.removeValue(forKey: id)?.worker
        await worker?.cancel()
    }

    func hasWorker(id: String) -> Bool {
        entries[id] != nil
    }

    private func removeWorker(id: String, token: UploadInputStandardizationToken) {
        guard entries[id]?.token == token else { return }
        entries[id] = nil
    }
}
