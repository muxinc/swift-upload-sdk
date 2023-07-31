//
//  UploadItemViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/16/23.
//

import Foundation
import AVFoundation
import MuxUploadSDK

class ThumbnailModel: ObservableObject {
    
    func startExtractingThumbnail() {
        guard thumbnailGenerator == nil else {
            return
        }
        
        thumbnailGenerator = AVAssetImageGenerator(asset: asset)
        thumbnailGenerator?.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime.zero)]) {
            requestedTime,
            image,
            actualTime,
            result,
            error
            in
            switch result {
            case .cancelled: do {
                SwiftUploadSDKExample.logger.debug("Thumbnail request canceled")
            }
            case .failed: do {
                SwiftUploadSDKExample.logger.error("Failed to extract thumnail: \(error?.localizedDescription ?? "unknown")")
            }
            case .succeeded: do {
                Task.detached {
                    await MainActor.run {
                        if (self.thumbnail == nil) {
                            self.thumbnail = image
                        }
                    }
                }
            }
            @unknown default:
                fatalError()
            }
        }
        
    }
    
    private let asset: AVAsset
    private let upload: DirectUpload
    private var thumbnailGenerator: AVAssetImageGenerator?
    
    @Published var thumbnail: CGImage?
    @Published var uploadProgress: DirectUpload.TransportStatus?
    
    init(asset: AVAsset, upload: DirectUpload) {
        self.asset = asset
        self.upload = upload
        
        upload.progressHandler = { state in
            SwiftUploadSDKExample.logger.info("Upload progressing from ViewModel: \(state.progress)")
            self.uploadProgress = state
        }
    }
}
