//
//  MuxUploadTests.swift
//

import Foundation
import XCTest
@testable import MuxUploadSDK

class MuxUploadTest: XCTestCase {

    func testInitializationInputStatus() throws {
        let upload = MuxUpload(
            uploadURL: URL(string: "https://www.example.com/upload")!,
            inputFileURL: URL(string: "file://var/mobile/Containers/Data/Application/Documents/myvideo.mp4")!
        )

        guard case MuxUpload.InputStatus.ready(_) = upload.inputStatus else {
            XCTFail("Expected initial input status to be ready")
            return
        }
    }

    

}

