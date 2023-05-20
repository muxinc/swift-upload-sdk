//
//  UploadInput.swift
//

import AVFoundation
import Foundation

// Internal representation of the upload input as it is
// undergoing non-standard
struct UploadInput {

    internal enum Status {
        case ready(AVAsset)
        case started(AVAsset)
        case underInspection(AVAsset)
        case standardizing(AVAsset)
        case standardizationSucceeded(AVAsset)
        case standardizationFailed(AVAsset)
        case awaitingUploadConfirmation(UploadInfo)
        case uploadInProgress(UploadInfo)
        case uploadPaused(UploadInfo)
        case uploadSucceeded(UploadInfo)
        case uploadFailed(UploadInfo)
    }

    var status: Status

    var sourceAsset: AVAsset {
        switch status {
        case .ready(let sourceAsset):
            return sourceAsset
        case .started(let sourceAsset):
            return sourceAsset
        case .underInspection(let sourceAsset):
            return sourceAsset
        case .standardizing(let sourceAsset):
            return sourceAsset
        case .standardizationSucceeded(let sourceAsset):
            return sourceAsset
        case .standardizationFailed(let sourceAsset):
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

    var uploadInfo: UploadInfo? {
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

extension UploadInput {
    init(asset: AVAsset) {
        self.status = .ready(asset)
    }
}
