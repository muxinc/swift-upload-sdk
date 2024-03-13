//
//  SwiftUploadSDKExampleUnitTests.swift
//  SwiftUploadSDKExampleUnitTests
//
//  Created by Tomislav Kordic on 22.2.24..
//

import XCTest
@testable import MuxUploadSDK

import MuxUploadSDK

final class MemoryTests: XCTestCase {
    
    private let myServerBackend = FakeBackend(urlSession: URLSession(configuration: URLSessionConfiguration.default))
    
    func memoryFootprint() -> mach_vm_size_t? {
        // The `TASK_VM_INFO_COUNT` and `TASK_VM_INFO_REV1_COUNT` macros are too
        // complex for the Swift C importer, so we have to define them ourselves.
        let TASK_VM_INFO_COUNT = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let TASK_VM_INFO_REV1_COUNT = mach_msg_type_number_t(MemoryLayout.offset(of: \task_vm_info_data_t.min_address)! / MemoryLayout<integer_t>.size)
        var info = task_vm_info_data_t()
        var count = TASK_VM_INFO_COUNT
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard
            kr == KERN_SUCCESS,
            count >= TASK_VM_INFO_REV1_COUNT
        else { return nil }
        return info.phys_footprint
    }
    
    func getUploadFilePath() -> URL? {
        let bundle = Bundle(for: MemoryTests.self)
        let fileManager = FileManager.default
        let cwd = bundle.bundlePath
        guard let content = try? fileManager.contentsOfDirectory(atPath: cwd) else {
            XCTFail("five_min.mov file not found")
            return nil
        }
        guard let videoURL = try? bundle.url(forResource: "five_min", withExtension: "mov") else {
            XCTFail("five_min.mov file not found")
            return nil
        }
        return videoURL
    }
    
    func testChunkWorkerMemoryUsage() async throws {
        let chunkSizeInBytes = 6 * 1024 * 1024
        let videoURL = getUploadFilePath()
        let uploadURL = try await self.myServerBackend.createDirectUpload()
        let chunkedFile = ChunkedFile(chunkSize: chunkSizeInBytes)
        try chunkedFile.openFile(fileURL: videoURL!)
        try chunkedFile.seekTo(byte: 0)
        let startMemory = memoryFootprint()
        repeat {
            let chunk = try chunkedFile.readNextChunk().get()
            if (chunk.size() == 0) {
                break;
            }
            let chunkProgress = Progress(totalUnitCount: Int64(chunk.size()))
            let worker = ChunkWorker(
                uploadURL: uploadURL,
                chunkProgress: chunkProgress,
                maxRetries: 3
            )
            try await worker.directUpload(chunk: chunk)
        } while (true)
        let endMemory = memoryFootprint()
        if ((startMemory! * 2) < endMemory!) {
            XCTFail("We have mem leak, started with \(startMemory!) bytes, ended up with \(endMemory!) bytes")
        }
    }
    
    func testChunkedFileMemoryUsage() throws {
        let videoURL = getUploadFilePath()
        let chunkSizeInBytes = 6 * 1024 * 1024
        let chunkedFile = ChunkedFile(chunkSize: chunkSizeInBytes)
        try chunkedFile.openFile(fileURL: videoURL!)
        try chunkedFile.seekTo(byte: 0)
        let startMemory = memoryFootprint()
        repeat {
            let chunk = try chunkedFile.readNextChunk().get()
            Swift.print("Got chunk at position: \(chunk.startByte)")
            if (chunk.size() == 0) {
                break;
            }
        } while (true)
        let endMemory = memoryFootprint()
        if ((startMemory! * 2) < endMemory!) {
            XCTFail("We have mem leak, started with \(startMemory!) bytes, ended up with \(endMemory!) bytes")
        }
    }
    
    func testLargeUpload() async throws {
        // Construct custom upload options to upload a file in 6MB chunks
        let chunkSizeInBytes = 6 * 1024 * 1024
        let options = DirectUploadOptions(
            inputStandardization: .skipped,
            chunkSizeInBytes: chunkSizeInBytes,
            retryLimitPerChunk: 5
        )
        let putURL = try await self.myServerBackend.createDirectUpload()
        let videoURL = getUploadFilePath()
        
        let muxDirectUpload = DirectUpload(
            uploadURL: putURL,
            inputFileURL: videoURL!,
            options: options
        )
        
        muxDirectUpload.progressHandler = { state in
            // TODO: print progress, print memory usage
            Swift.print("Upload progress: " + (state.progress?.fractionCompleted.description)!)
        }
        let expectation = XCTestExpectation(description: "Upload task done(completed or failed)")
        muxDirectUpload.resultHandler = { result in
            switch result {
            case .success(let success):
                Swift.print("File uploaded successfully ")
                expectation.fulfill()
            case .failure(let error):
                Swift.print("Failed to upload file")
                expectation.fulfill()
            }
        }
        Swift.print("Starting upload video")
        muxDirectUpload.start()
        
        let result = await XCTWaiter().fulfillment(of: [expectation], timeout: 9000.0)
        switch result {
            //        case .completed:    XCTAssertEqual(muxDirectUpload.complete, true)
        case .timedOut:     do {
            Swift.print("Test timedout after 9000 seconds !!!")
            XCTFail()
        }
        default:   do {
            Swift.print("Test default option is to fail !!!")
            XCTFail()
           }
        }
        Swift.print("All done !!!")
    }
    
}
