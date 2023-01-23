//
//  ChunkWorker.swift
//  
//
//  Created by Emily Dixon on 3/1/23.
//

import XCTest
@testable import MuxUploadSDK

final class ChunkWorker: XCTestCase {

    func testResponseValidatorRetryCodes() throws {
        let validator = ChunkResponseValidator()
        for code in ChunkResponseValidator.RETRYABLE_HTTP_STATUS_CODES {
            switch validator.validate(statusCode: code) {
            case .retry: return ()
            default: return XCTFail("All Retryable codes should result in retries")
            }
        }
    }
    
    func testResponseValidatorSuccessCodes() throws {
        let validator = ChunkResponseValidator()
        for code in ChunkResponseValidator.ACCEPTABLE_HTTP_STATUS_CODES {
            switch validator.validate(statusCode: code) {
            case .proceed: return ()
            default: return XCTFail("All Acceptable codes should result in proceeding")
            }
        }
    }
    
}
