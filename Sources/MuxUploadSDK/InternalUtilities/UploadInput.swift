//
//  UploadInput.swift
//

import AVFoundation
import Foundation

// Internal representation of the upload input as it is
// undergoing non-standard
struct UploadInput {

    internal enum Status {
        case ready(AVAsset, UploadInfo)
        case started(AVAsset, UploadInfo)
        case underInspection(AVAsset, UploadInfo)
        case standardizing(AVAsset, UploadInfo)
        case standardizationSucceeded(
            source: AVAsset,
            standardized: AVAsset?,
            uploadInfo: UploadInfo
        )
        case standardizationFailed(AVAsset, UploadInfo)
        case awaitingUploadConfirmation(UploadInfo)
        case uploadInProgress(UploadInfo, DirectUpload.TransportStatus)
        case uploadPaused(UploadInfo, DirectUpload.TransportStatus)
        case uploadSucceeded(UploadInfo, DirectUpload.SuccessDetails)
        case uploadFailed(UploadInfo, DirectUploadError)
    }

    var status: Status

    var sourceAsset: AVAsset {
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
        case .awaitingUploadConfirmation(let uploadInfo):
            return uploadInfo.sourceAsset()
        case .uploadInProgress(let uploadInfo, _):
            return uploadInfo.sourceAsset()
        case .uploadSucceeded(let uploadInfo, _):
            return uploadInfo.sourceAsset()
        case .uploadFailed(let uploadInfo, _):
            return uploadInfo.sourceAsset()
        case .uploadPaused(let uploadInfo, _):
            return uploadInfo.sourceAsset()
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
        case .awaitingUploadConfirmation(let uploadInfo):
            return uploadInfo
        case .uploadInProgress(let uploadInfo, _):
            return uploadInfo
        case .uploadPaused(let uploadInfo, _):
            return uploadInfo
        case .uploadSucceeded(let uploadInfo, _):
            return uploadInfo
        case .uploadFailed(let uploadInfo, _):
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
        case .uploadInProgress(_, let transportStatus):
            return transportStatus
        case .uploadPaused(_, let transportStatus):
            return transportStatus
        case .uploadSucceeded(_, let successDetails):
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
            status = .uploadInProgress(uploadInfo, startingTransportStatus)
        } else {
            return
        }
    }

    mutating func processUploadSuccess(
        transportStatus: DirectUpload.TransportStatus
    ) {
        if case UploadInput.Status.uploadInProgress(let info, _) = status {
            status = .uploadSucceeded(info, DirectUpload.SuccessDetails(finalState: transportStatus))
        } else {
            return
        }
    }

    mutating func processUploadFailure(error: DirectUploadError) {
        status = .uploadFailed(uploadInfo, error)
    }

}

extension UploadInput.Status: Equatable { }

extension UploadInput {
    init(
        asset: AVAsset,
        info: UploadInfo
    ) {
        self.status = .ready(asset, info)
    }
}
