//
//  MuxUpload+PhotosKit.swift
//

import Foundation
import Photos

extension PHAsset {

    /// Convenience method that requests an ``AVAsset``
    /// containing audiovisual media associated with the callee
    /// ``PHAsset``. If the request succeeds ``MuxUpload``
    /// is initialized with the received ``AVAsset``
    ///
    /// A ``MuxUpload`` can only be initialized from a ``PHAsset``
    /// whose ``PHAsset.mediaType`` is ``PHAssetMediaType.video``
    ///
    /// - Parameters:
    ///    - imageManager: an object that facilitates retrieval
    ///    of asset data associated with the callee
    ///    - requestOptions: options used when requesting
    ///    an ``AVAsset`` from a ``PHImageManager`
    ///    - options: options used to control the direct
    ///    upload of the input to Mux
    ///    - uploadURL: the URL of your direct upload, see
    ///    the [direct upload guide](https://docs.mux.com/api-reference#video/operation/create-direct-upload)
    ///    - completion: called when initialized ``MuxUpload``
    ///    is ready, receives nil if the asset data request
    ///    failed or if the ``PHAsset`` callee is not a video
    func prepareForDirectUpload(
        from imageManager: PHImageManager = .default(),
        requestOptions: PHVideoRequestOptions,
        options: UploadOptions = .default,
        uploadURL: URL,
        completion: @escaping (MuxUpload?) -> ()
    ) {
        if mediaType != .video {
            completion(nil)
            return
        }

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
