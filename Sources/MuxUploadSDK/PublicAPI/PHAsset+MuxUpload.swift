//
//  MuxUpload+PhotosKit.swift
//

import Foundation
import Photos

extension PHAsset {

    /// Asynchronously initializes ``MuxUpload`` from a
    /// requesting for an ``AVAsset`` containing the input.
    /// A ``MuxUpload`` can only be initialized from a ``PHAsset``
    /// whose ``PHAsset.mediaType`` is
    /// ``PHAssetMediaType.video``.
    ///
    ///
    /// - Parameters:
    ///    - imageManager: Photos image manager
    ///    - requestOptions: options used when requesting
    ///    an ``AVAsset`` from the `imageManager`
    ///    - uploadURL: the direct upload URL
    ///    - options: the upload settings
    ///    - completion: receives the initialized MuxUpload
    ///    when it is ready, receives nil if initialization
    ///    failed or if the ``PHAsset`` is not a video.
    func prepareForDirectUpload(
        from imageManager: PHImageManager = .default(),
        requestOptions: PHVideoRequestOptions,
        uploadURL: URL,
        options: UploadOptions,
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
