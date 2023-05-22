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
        case uploadInProgress(UploadInfo)
        case uploadPaused(UploadInfo)
        case uploadSucceeded(UploadInfo)
        case uploadFailed(UploadInfo)
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
        case .uploadInProgress(let uploadInfo):
            return uploadInfo.sourceAsset()
        case .uploadSucceeded(let uploadInfo):
            return uploadInfo.sourceAsset()
        case .uploadFailed(let uploadInfo):
            return uploadInfo.sourceAsset()
        case .uploadPaused(let uploadInfo):
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
        case .uploadInProgress(let uploadInfo):
            return uploadInfo
        case .uploadPaused(let uploadInfo):
            return uploadInfo
        case .uploadSucceeded(let uploadInfo):
            return uploadInfo
        case .uploadFailed(let uploadInfo):
            return uploadInfo
        }
    }
}

extension UploadInput.Status: Equatable {

}

extension UploadInput {
    init(
        asset: AVAsset,
        info: UploadInfo
    ) {
        self.status = .ready(asset, info)
    }
}
