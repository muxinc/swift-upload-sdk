//
//  FakeBackend.swift
//  Test App
//
//  Created by Emily Dixon on 5/8/23.
//

import Foundation

/// This class stands in for the trusted environment required to create a Direct Upload.
/// A production app should request authenticated upload URLs from its trusted environment.
///
/// **Never include Mux API credentials in a production app.** This example does so only
/// to keep the sample self-contained.
class FakeBackend {
    
    func createDirectUpload(maxResolutionTier: String) async throws -> URL {
        let request = try {
            var req = try URLRequest(url: fullURL(forEndpoint: "uploads"))
            req.httpBody = try jsonEncoder.encode(
                CreateUploadPost(maxResolutionTier: maxResolutionTier)
            )
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("application/json", forHTTPHeaderField: "accept")
            
            guard let basicAuthCredentialData = "\(Self.muxAccessTokenID):\(Self.muxAccessSecretKey)".data(using: .utf8) else {
                throw CreateUploadError(message: "failed to encode authorization credentials")
            }
            let basicAuthCredential = basicAuthCredentialData.base64EncodedString()
            req.addValue("Basic \(basicAuthCredential)", forHTTPHeaderField: "Authorization")
            
            return req
        }()

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CreateUploadError(message: "invalid response type")
        }

        if (200...299).contains(httpResponse.statusCode) {
            let responseData = try jsonDecoder.decode(CreateUploadResponseContainer.self, from: data).data
            guard let uploadURL = URL(string:responseData.url) else {
                throw CreateUploadError(message: "invalid upload url")
            }
            self.logger.notice("Created direct upload id=\(responseData.id, privacy: .public) status=\(responseData.status, privacy: .public)")
            return uploadURL
        } else {
            self.logger.error("Direct Upload creation failed with HTTP \(httpResponse.statusCode)")
            throw CreateUploadError(
                message: "Direct Upload creation failed with HTTP \(httpResponse.statusCode)"
            )
        }
    }
    
    /// Generates a full URL for a given endpoint in the Mux Video public API
    private func fullURL(forEndpoint: String) throws -> URL {
        guard let url = URL(string: "https://api.mux.com/video/v1/\(forEndpoint)") else {
            throw CreateUploadError(message: "bad endpoint")
        }
        return url
    }
    
    private let logger = SwiftUploadSDKExample.logger

    // This sample-only helper creates the Direct Upload URL passed to the SDK.
    private let urlSession: URLSession
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder
    
    private static let muxAccessTokenID = "YOUR ACCESS TOKEN ID HERE"
    private static let muxAccessSecretKey = "YOUR SECRET KEY HERE"

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

struct CreateUploadError: Error {
    let message: String
}

fileprivate struct CreateUploadPost: Encodable {
    var newAssetSettings: NewAssetSettings
    var corsOrigin: String = "*"

    init(maxResolutionTier: String) {
        self.newAssetSettings = NewAssetSettings(
            maxResolutionTier: maxResolutionTier
        )
    }
}

fileprivate struct NewAssetSettings: Encodable {
    var playbackPolicy: [String] = ["public"]
    var passthrough: String = "Extra video data. This can be any data and it's for your use"
    var normalizeAudio: Bool = true
    var test: Bool = false
    var maxResolutionTier: String
}

fileprivate struct CreateUploadResponse: Decodable {
    var url: String
    var id: String
    var timeout: Int64
    var status: String
}

fileprivate struct CreateUploadResponseContainer: Decodable {
    var data: CreateUploadResponse
}
