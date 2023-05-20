//
//  MuxUpload+AVFoundation.swift
//

import AVFoundation
import Foundation

extension MuxUpload {

    /// Initializes a MuxUpload from an ``AVAsset``
    ///
    /// - Parameters:
    ///    - uploadURL: the URL of the direct upload that's
    ///    included in the create a new direct upload URL
    ///    [response](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///     - inputAsset: the asset containing audiovisual
    ///     media to be used as the input for the direct
    ///     upload
    ///     - options: options used to control the direct
    ///    upload of the input to Mux
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
