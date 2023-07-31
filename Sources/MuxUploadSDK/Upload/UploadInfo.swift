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
    /**
     Unique internal ID for the upload
     */
    var id: String = UUID().uuidString
    
    /**
     URI of the upload destination
     */
    var uploadURL: URL

    /**
     Options selected for the upload
     */
    var options: DirectUploadOptions
}

extension UploadInfo: Equatable { }

extension UploadInfo {
    func sourceAsset() -> AVAsset {
        AVAsset(
            url: uploadURL
        )
    }
}
