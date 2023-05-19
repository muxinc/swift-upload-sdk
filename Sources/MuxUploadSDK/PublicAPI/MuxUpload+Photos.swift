//
//  MuxUpload+PhotosKit.swift
//

import Foundation
import Photos

extension MuxUpload {
    /// Asynchronously creates a MuxUpload using a ``PHAsset``
    ///
    /// - Parameters:
    ///    - imageManager: Photos image manager
    ///    - inputAsset: the upload input asset, its
    ///    ``PHAsset.mediaType`` needs to be ``PHAssetMediaType.video``
    ///    - uploadURL: the direct upload URL
    ///    - transportSettings: upload transport settings
    ///    - optOutOfEventTracking: opts out of SDK event reporting
    ///    - standardizationSettings: if enabled the SDK checks
    ///    if the input file is in a standard input format,
    ///    attempts local conversion if it is non-standard
    ///    - completion: receives the initialized MuxUpload
    ///    when it is ready, receives nil if initialization
    ///    failed
    public static func makeByExporting(
        from imageManager: PHImageManager = .default(),
        using inputAsset: PHAsset,
        requestOptions: PHVideoRequestOptions,
        uploadURL: URL,
        settings: UploadSettings,
        completion: @escaping (MuxUpload?) -> ()
    ) {

        if inputAsset.mediaType != .video {
            completion(nil)
            return
        }

        imageManager
            .requestAVAsset(
                forVideo: inputAsset,
                options: requestOptions
            ) { asset, audioMix, params in
                let upload: MuxUpload? = asset.map { unwrappedAsset in
                    MuxUpload(
                        uploadURL: uploadURL,
                        inputAsset: unwrappedAsset,
                        settings: settings
                    )
                }

                completion(upload)
            }
    }
}
