//
//  UploadItemViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/16/23.
//

import Foundation
import AVFoundation

class UploaadItemViewModel: ObservableObject {
    
    func extractThumbnail() {
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
                Test_AppApp.logger.debug("Thumbnail request canceled")
            }
            case .failed: do {
                Test_AppApp.logger.error("Failed to extract thumnail: \(error?.localizedDescription ?? "unknown")")
            }
            case .succeeded: do {
                Task.detached {
                    await MainActor.run {
                        self.thumbnail = image
                    }
                }
            }
            @unknown default:
                fatalError()
            }
        }
        
    }
    
    private let asset: AVAsset
    private var thumbnailGenerator: AVAssetImageGenerator?
    
    @Published var thumbnail: CGImage?
    
    init(asset: AVAsset) {
        self.asset = asset
    }
}
