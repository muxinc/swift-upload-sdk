//
//  MuxUpload+PhotosKit.swift
//

import Foundation
import Photos

extension PHAsset {

    /// Convenience method that requests an ``AVAsset``
    /// containing audiovisual media associated with the callee
    /// ``PHAsset``. If the request succeeds ``MuxUpload``
    /// is initialized with the received ``AVAsset``. This method
    /// enables network access when performing its request.
    ///
    /// A ``MuxUpload`` can only be initialized from a ``PHAsset``
    /// whose ``PHAsset.mediaType`` is ``PHAssetMediaType.video``.
    ///
    /// - Parameters:
    ///    - imageManager: an object that facilitates retrieval
    ///    of asset data associated with the callee
    ///    - options: options used to control the direct
    ///    upload of the input to Mux
    ///    - uploadURL: the URL of your direct upload, see
    ///    the [direct upload guide](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///    - completion: called when initialized ``MuxUpload``
    ///    is ready, receives nil if the asset data request
    ///    failed or if the ``PHAsset`` callee is not a video
    func prepareForDirectUpload(
        from imageManager: PHImageManager = .default(),
        options: UploadOptions = .default,
        uploadURL: URL,
        completion: @escaping (MuxUpload?) -> ()
    ) {
        if mediaType != .video {
            completion(nil)
            return
        }

        let requestOptions = PHVideoRequestOptions()
        requestOptions.isNetworkAccessAllowed = true
        requestOptions.deliveryMode = .highQualityFormat

        imageManager
            .requestAVAsset(
                forVideo: self,
                options: requestOptions
            ) { asset, audioMix, params in
                let upload: MuxUpload? = asset.map { unwrappedAsset in
                    MuxUpload(
                        uploadURL: uploadURL,
                        inputAsset: unwrappedAsset,
                        options: options
                    )
                }

                completion(upload)
            }
    }
}
