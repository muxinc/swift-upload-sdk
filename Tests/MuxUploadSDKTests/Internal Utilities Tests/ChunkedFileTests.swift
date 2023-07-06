//
//  ChunkedFileTests.swift
//  
//
//  Created by Emily Dixon on 2/23/23.
//

import Foundation
import XCTest
@testable import MuxUploadSDK

final class ChunkedFileTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
    }
    
    func testResetsPositionAfterClose() throws {
        let chunkSize = 1 * 1000 * 1000 // 1M (base 10)
        let testFileURL = try writeAFile(at: "testfile", sizeMBBeforeRemainder: 1) // File size: 1M (base 10) + 1 bytes
        let file = ChunkedFile(chunkSize: chunkSize)
        try file.openFile(fileURL: testFileURL)
        
        let firstChunkResult = file.readNextChunk()
        file.close()
        try file.openFile(fileURL: testFileURL)
        
        XCTAssertNoThrow(try firstChunkResult.get(), "Read after reopen should succeed")
        let firstChunk = try firstChunkResult.get()
        XCTAssertEqual(
            firstChunk.size(),
            chunkSize,
            "Read after reopen should be a full chunk"
        )
    }
    
    func testReadsInChunksUntilEnd() throws {
        let chunkSize = 1 * 1000 * 1000 // 1M (base 10)
        let testFileURL = try writeAFile(at: "testfile", sizeMBBeforeRemainder: 1) // File size: 1M (base 10) + 1 bytes
        let file = ChunkedFile(chunkSize: chunkSize)
        try file.openFile(fileURL: testFileURL)
        
        let firstChunkResult = file.readNextChunk()
        XCTAssertNoThrow(try firstChunkResult.get(), "First read should succeed")
        let firstChunk = try firstChunkResult.get()
        XCTAssertEqual(
            firstChunk.size(),
            chunkSize,
            "First chunk read should be a full chunk"
        )
        XCTAssertEqual(
            firstChunk.size(),
            firstChunk.chunkData.count,
            "Chunk size and length of chunk Data should agree"
        )
        
        let secondChunkResult = file.readNextChunk()
        XCTAssertNoThrow(try secondChunkResult.get(), "Second read should succeed")
        let readLen = try secondChunkResult.get().size()
        XCTAssertEqual(
            readLen,
            1,
            "Second read should have the remainder of the file"
        )
        
        let thirdChunkResult = file.readNextChunk()
        XCTAssertNoThrow(try secondChunkResult.get(), "Third read should succeed")
        XCTAssertEqual(
            try thirdChunkResult.get().size(),
            0,
            "Second read should have the remainder of the file"
        )
        
        file.close()
    }
    
    func testMisuseBeforeOpen() throws {
        let file = ChunkedFile(chunkSize: 10 * 1000 * 1000)

        let readResult = file.readNextChunk()
        switch readResult {
        case .success(_): return XCTFail("readNextChunk should fail before open")
        case .failure(let error): do {
            switch error as! ChunkedFileError {
            case .invalidState(_): return ()
            default: return XCTFail("readNextChunk should throw .invalidState")
            } // switch error as! ChunkedFileError
        } // case .failure... do {
        } // switch readResult
    }
    
    func testMisuseAferClose() throws {
        let testFileURL = try writeAFile(at: "testfile")
        let file = ChunkedFile(chunkSize: 10 * 1000 * 1000)
        
        try file.openFile(fileURL: testFileURL)
        file.close()
        
        let chunkResult = file.readNextChunk()
        switch chunkResult {
        case .success(_): return XCTFail("read after close should not succeed")
        case .failure(let error): switch error as! ChunkedFileError {
        case.invalidState(_): do {}
        default: return XCTFail("Read after close should return invalid state error")
        }
        }
    }
    
    // Writes a file in 1MB chunks, separated by newlines. The final file's size in (base-10) megabytes is equal to (sizeBeforeRemainder + (sizeBeforeRemainder / 1M))
    private func writeAFile(at filename: String, sizeMBBeforeRemainder size: UInt64 = 10) throws -> URL {
        let url = URL(string: filename, relativeTo: FileManager.default.temporaryDirectory)!
        
        do {
            try FileManager.default.removeItem(at: url)
        } catch { }
        let createdFile = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard createdFile else { throw XCTestError(_nsError: NSError()) }
        
        let line = "\(String(repeating: "0123456789", count: 100 * 1000))\n" // 1M + 1
        let fileHandle = try FileHandle(forWritingTo: url)
        for _ in 1...size {
            let fileData = line.data(using: .ascii)!  // 1 character per byte
            try fileHandle.write(contentsOf: fileData)
        }
        try fileHandle.close()
        return url
    }
}
