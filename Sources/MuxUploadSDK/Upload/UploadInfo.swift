//
//  UploadInfo.swift
//  Mux Upload SDK
//
//  Created by Emily Dixon on 2/10/23.
//

import Foundation

/**
 Internal representation of a video upload
 */
struct UploadInfo : Codable {

    var id: String
    /**
     URI of the upload's destinatoin
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
