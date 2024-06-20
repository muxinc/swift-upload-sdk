//
//  DirectUpload+AVFoundation.swift
//

import AVFoundation
import Foundation

extension DirectUpload {

    /// Initializes a DirectUpload from an ``AVAsset``
    ///
    /// - Parameters:
    ///    - uploadURL: the URL of your direct upload, see
    ///    the [direct upload guide](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///     - inputAsset: the asset containing audiovisual
    ///     media to be used as the input for the direct
    ///     upload
    ///     - options: options used to control the direct
    ///    upload of the input to Mux
    public convenience init(
        uploadURL: URL,
        inputAsset: AVAsset,
        options: DirectUploadOptions
    ) {
        guard let urlAsset = inputAsset as? AVURLAsset else {
            fatalError(
                "Only assets with URLs can be uploaded"
            )
        }

        self.init(
            input: UploadInput(
                asset: urlAsset,
                info: UploadInfo(
                    uploadURL: uploadURL,
                    options: options
                )
            ),
            uploadManager: .shared,
            inputInspector: .shared
        )
    }

}
