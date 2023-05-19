//
//  MuxUpload+AVFoundation.swift
//

import AVFoundation
import Foundation

extension MuxUpload {

    public convenience init(
        uploadURL: URL,
        inputAsset: AVAsset,
        settings: UploadSettings
    ) {
        let input = UploadInput(status: .ready(inputAsset))

        self.init(
            input: input,
            settings: settings,
            uploadManager: .shared
        )
    }

}
