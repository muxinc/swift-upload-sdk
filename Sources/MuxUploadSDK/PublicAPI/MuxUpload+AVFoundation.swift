//
//  MuxUpload+AVFoundation.swift
//

import AVFoundation
import Foundation

extension MuxUpload {

    public convenience init(
        uploadURL: URL,
        inputAsset: AVAsset,
        transportSettings: TransportSettings = TransportSettings(),
        optOutOfEventTracking: Bool,
        standardizationSettings: StandardizationSettings = .enabled(resolution: .preset1920x1080)
    ) {

        let input = UploadInput(status: .ready(inputAsset))

        self.init(
            input: input,
            transportSettings: transportSettings,
            optOutOfEventTracking: optOutOfEventTracking,
            standardizationSettings: standardizationSettings,
            uploadManager: .shared
        )
    }

}
