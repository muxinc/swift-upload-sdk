//
//  UploadInput+Fixtures.swift
//

import AVFoundation
import Foundation
import XCTest

@testable import MuxUploadSDK

extension UploadInput {

    static func mockStartedInput() throws -> Self {
        let uploadURL = try XCTUnwrap(
            URL(string: "https://www.example.com/upload")
        )

        let videoInputURL = try XCTUnwrap(
            URL(string: "file://path/to/dummy/file/")
        )

        let uploadInputAsset = AVAsset(
            url: videoInputURL
        )

        return UploadInput(
            status: .started(
                uploadInputAsset,
                UploadInfo(
                    uploadURL: uploadURL,
                    options: .default
                )
            )
        )
    }
}
