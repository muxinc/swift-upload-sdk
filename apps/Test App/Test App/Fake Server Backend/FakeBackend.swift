//
//  FakeBackend.swift
//  Test App
//
//  Created by Emily Dixon on 5/8/23.
//

import Foundation

/// This class "fakes" the server backend necessary to compvare an upload workflow.
/// In your production use case, a backend server should take care of creating upload URLs
///
/// **You should never build Mux server API ceredentials into a real app**. We do it in this example for brevity only
class FakeBackend {
    
    func createDirectUpload() async throws -> URL {
        let request = try {
            var req = try URLRequest(url:fullURL(forEndpoint: "uploads"))
            req.httpBody = try jsonEncoder.encode(NewAssetSettings())
            return req
        }()
        
        let (data, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           (200...299).contains(httpResponse.statusCode) {
            let responseData = try jsonDecoder.decode(CreateUploadResponseContainer.self, from: data).data
            guard let uploadURL = URL(string:responseData.url) else {
                throw CreateUploadError(message: "invalid upload url")
            }
            return uploadURL
        } else {
            throw CreateUploadError(message: "not an http url session")
        }
    }
    
    /// Generates a full URL for a given endpoint in the Mux Video public API
    private func fullURL(forEndpoint: String) throws -> URL {
        guard let url = URL(string: "https://api.mux.com/video/\(forEndpoint)") else {
            throw CreateUploadError(message: "bad endpoint")
        }
        return url
    }
    
    let urlSession: URLSession
    let jsonEncoder: JSONEncoder
    let jsonDecoder: JSONDecoder
    
    let MUX_ACCESS_KEY_ID = "YOUR ACCESS KEY ID"
    let MUX_ACCESS_KEY_SECRET = "YOUR ACCESS KEY SECRET"
    
    init(urlSession: URLSession) {
        self.urlSession = urlSession
        self.jsonEncoder = JSONEncoder()
        self.jsonEncoder.keyEncodingStrategy = JSONEncoder.KeyEncodingStrategy.convertToSnakeCase
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.keyDecodingStrategy = JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase
    }
    
    convenience init() {
        self.init(urlSession: URLSession(configuration: URLSessionConfiguration.default))
    }
}

struct CreateUploadError : Error {
    let message: String
}


fileprivate struct CreateUploadPost: Codable {
    var newAssetSettings: NewAssetSettings = NewAssetSettings()
    var corsOrigin: String = "*"
}

fileprivate struct NewAssetSettings: Codable {
    var playbackPolicy: [String] = ["public"]
    var passthrough: String = "Extra video data. This can be any data and it's for your use"
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
