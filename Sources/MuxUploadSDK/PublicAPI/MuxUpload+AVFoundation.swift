//
//  MuxUpload+AVFoundation.swift
//

import AVFoundation
import Foundation

extension MuxUpload {

    public convenience init(
        uploadURL: URL,
        inputAsset: AVAsset,
        options: UploadOptions
    ) {
        self.init(
            input: UploadInput(asset: inputAsset),
            options: options,
            uploadManager: .shared
        )
    }

}
