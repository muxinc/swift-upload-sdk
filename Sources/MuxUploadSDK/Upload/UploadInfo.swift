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
    var inputURL: URL
    /**
     Options selected for the upload
     */
    var options: UploadOptions
}

extension UploadInfo: Equatable { }

extension UploadInfo {
    func sourceAsset() -> AVAsset {
        AVAsset(
            url: uploadURL
        )
    }
}
