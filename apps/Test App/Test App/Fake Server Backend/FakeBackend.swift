//
//  FakeBackend.swift
//  Test App
//
//  Created by Emily Dixon on 5/8/23.
//

import Foundation

/// This class "fakes" the server backend necessary to compvare an upload workflow.
///  In your production use case, a backend server should take care of creating upload URLs
///
/// **In your real application, you should never build Mux server API ceredentials into your app**.
/// It is done in this example for brevity and clarity only
class FakeBackend {
    
    
    var MUX_ACCESS_KEY_ID = "YOUR ACCESS KEY ID"
    var MUX_ACCESS_KEY_SECRET = "YOUR ACCESS KEY SECRET"
}

fileprivate struct CreateUploadPost: Codable {
    var newAssetSettings: NewAssetSettings = NewAssetSettings()
    var corsOrigin: String = "*"
}

fileprivate struct NewAssetSettings: Codable {
    var playbackPolicy: [String] = ["public"]
    var passthrough: String = "Extra video data. This can be anything"
    var mp4Support: String = "standard"
    var normalizeAudio: Bool = true
    var test: Bool = false
}

fileprivate struct CreateUploadResponse: Decodable {
    var url: String
    var assetId: String
    var timeout: Int64
    var status: String
    var newAssetSettings: NewAssetSettings
}

fileprivate struct CreateUploadResponseContainer: Decodable {
    var data: CreateUploadResponse
}
