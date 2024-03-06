//
//  ChunkWorker.swift
//  
//
//  Created by Emily Dixon on 3/1/23.
//

import XCTest
@testable import MuxUploadSDK

class ChunkWorkerTests: XCTestCase {
    func testResponseValidatorRetryCodes() throws {
        let validator = ChunkResponseValidator()
        for code in ChunkResponseValidator.retryableHTTPStatusCodes {
            switch validator.validate(statusCode: code) {
            case .retry: return ()
            default: return XCTFail("All Retryable codes should result in retries")
            }
        }
    }
    
    func testResponseValidatorSuccessCodes() throws {
        let validator = ChunkResponseValidator()
        for code in ChunkResponseValidator.acceptableHTTPStatusCodes {
            switch validator.validate(statusCode: code) {
            case .proceed: return ()
            default: return XCTFail("All Acceptable codes should result in proceeding")
            }
        }
    }
    
}
