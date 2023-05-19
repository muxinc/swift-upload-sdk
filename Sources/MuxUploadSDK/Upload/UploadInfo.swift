//
//  UploadInfo.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/10/23.
//

import AVFoundation
import Foundation

/**
 Internal representation of a video upload
 */
struct UploadInfo : Codable {

    var id: String
    /**
     URI of the upload destination
     */
    var uploadURL: URL
    /**
     file::// URL to the video file to be uploaded
     */
    var videoFile: URL
    /**
     The size of the outgoing chunks, in bytes
     */
    var chunkSize: Int
    /**
     The number of failed upload attempts, per chunk, to retry
     **/
    var retriesPerChunk: Int
    /**
     True if the user opted out of sending us performance metrics
     */
    var optOutOfEventTracking: Bool
}

extension UploadInfo {

    init(
        id: String,
        uploadURL: URL,
        videoFile: URL,
        transportSettings: UploadOptions.Transport,
        optOutOfEventTracking: Bool
    ) {
        self.id = id
        self.uploadURL = uploadURL
        self.videoFile = videoFile
        self.chunkSize = transportSettings.chunkSize
        self.retriesPerChunk = transportSettings.retriesPerChunk
        self.optOutOfEventTracking = optOutOfEventTracking
    }

    func sourceAsset() -> AVAsset {
        AVAsset(
            url: uploadURL
        )
    }
}
