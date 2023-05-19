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
        let input = UploadInput(status: .ready(inputAsset))

        self.init(
            input: input,
            options: options,
            uploadManager: .shared
        )
    }

}
