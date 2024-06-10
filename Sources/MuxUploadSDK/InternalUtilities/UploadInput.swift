//
//  UploadInput.swift
//

import AVFoundation
import Foundation

// Internal representation of the upload input as it is
// undergoing non-standard
struct UploadInput {

    internal enum Status {
        case ready(AVURLAsset, UploadInfo)
        case started(AVURLAsset, UploadInfo)
        case underInspection(AVURLAsset, UploadInfo)
        case standardizing(AVURLAsset, UploadInfo)
        case standardizationSucceeded(
            source: AVURLAsset,
            standardized: AVURLAsset?,
            uploadInfo: UploadInfo
        )
        case standardizationFailed(AVURLAsset, UploadInfo)
        case awaitingUploadConfirmation(AVURLAsset,UploadInfo)
        case uploadInProgress(AVURLAsset, UploadInfo, DirectUpload.TransportStatus)
        case uploadPaused(AVURLAsset, UploadInfo, DirectUpload.TransportStatus)
        case uploadSucceeded(AVURLAsset, UploadInfo, DirectUpload.SuccessDetails)
        case uploadFailed(AVURLAsset, UploadInfo, DirectUploadError)
    }

    var status: Status

    var sourceAsset: AVURLAsset {
        switch status {
        case .ready(let sourceAsset, _):
            return sourceAsset
        case .started(let sourceAsset, _):
            return sourceAsset
        case .underInspection(let sourceAsset, _):
            return sourceAsset
        case .standardizing(let sourceAsset, _):
            return sourceAsset
        case .standardizationSucceeded(let sourceAsset, _, _):
            return sourceAsset
        case .standardizationFailed(let sourceAsset, _):
            return sourceAsset
        case .awaitingUploadConfirmation(let sourceAsset, _):
            return sourceAsset
        case .uploadInProgress(let sourceAsset, _, _):
            return sourceAsset
        case .uploadSucceeded(let sourceAsset, _, _):
            return sourceAsset
        case .uploadFailed(let sourceAsset, _, _):
            return sourceAsset
        case .uploadPaused(let sourceAsset, _, _):
            return sourceAsset
        }
    }

    var uploadInfo: UploadInfo {
        switch status {
        case .ready(_, let uploadInfo):
            return uploadInfo
        case .started(_, let uploadInfo):
            return uploadInfo
        case .underInspection(_, let uploadInfo):
            return uploadInfo
        case .standardizing(_, let uploadInfo):
            return uploadInfo
        case .standardizationSucceeded(_, _, let uploadInfo):
            return uploadInfo
        case .standardizationFailed(_, let uploadInfo):
            return uploadInfo
        case .awaitingUploadConfirmation(_, let uploadInfo):
            return uploadInfo
        case .uploadInProgress(_, let uploadInfo, _):
            return uploadInfo
        case .uploadPaused(_, let uploadInfo, _):
            return uploadInfo
        case .uploadSucceeded(_, let uploadInfo, _):
            return uploadInfo
        case .uploadFailed(_, let uploadInfo, _):
            return uploadInfo
        }
    }

    var transportStatus: DirectUpload.TransportStatus? {
        switch status {
        case .ready:
            return nil
        case .started:
            return nil
        case .underInspection:
            return nil
        case .standardizing:
            return nil
        case .standardizationSucceeded:
            return nil
        case .standardizationFailed:
            return nil
        case .awaitingUploadConfirmation:
            return nil
        case .uploadInProgress(_, _, let transportStatus):
            return transportStatus
        case .uploadPaused(_, _, let transportStatus):
            return transportStatus
        case .uploadSucceeded(_, _, let successDetails):
            return successDetails.finalState
        case .uploadFailed:
            return nil
        }
    }
}

extension UploadInput {

    mutating func processUploadCancellation() {
        if case UploadInput.Status.ready = status {
            return
        }

        status = .ready(sourceAsset, uploadInfo)
    }

    mutating func processStartNetworkTransport(
        startingTransportStatus: DirectUpload.TransportStatus
    ) {
        if case UploadInput.Status.underInspection = status {
            status = .uploadInProgress(sourceAsset, uploadInfo, startingTransportStatus)
        } else {
            return
        }
    }

    mutating func processUploadSuccess(
        transportStatus: DirectUpload.TransportStatus
    ) {
        if case UploadInput.Status.uploadInProgress(let asset, let info, _) = status {
            status = .uploadSucceeded(asset, info, DirectUpload.SuccessDetails(finalState: transportStatus))
        } else {
            return
        }
    }

    mutating func processUploadFailure(error: DirectUploadError) {
        status = .uploadFailed(sourceAsset, uploadInfo, error)
    }

}

extension UploadInput.Status: Equatable { }

extension UploadInput {
    init(
        asset: AVURLAsset,
        info: UploadInfo
    ) {
        self.status = .ready(asset, info)
    }
}
