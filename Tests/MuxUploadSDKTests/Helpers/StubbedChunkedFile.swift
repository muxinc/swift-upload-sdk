//
//  ChunkedFileMocked.swift
//  
//
//  Created by Emily Dixon on 3/3/23.
//

import Foundation
@testable import MuxUploadSDK


class StubbedChunkedFile: ChunkedFile {
    
    private var dummyChunksSent = 0
    private var open: Bool = false
    
    var dummyChunkFactory: (Int) -> Result<FileChunk, Error> = {  StubbedChunkedFile.makeDummyFileChunk($0) }
    var openShouldThrow: Bool = false
    
    override func openFile(fileURL: URL) throws {
        if openShouldThrow {
            throw ChunkedFileError.invalidState("test err")
        }
        
        open = true
    }
    
    override func close() {
        open = false
    }
    
    override func readNextChunk() -> Result<FileChunk, Error> {
        if !open {
            return Result.failure(ChunkedFileError.invalidState("cannot read while closed"))
        }
        let sequenceNum = dummyChunksSent
        dummyChunksSent += 1
        return dummyChunkFactory(sequenceNum)
    }
}

extension StubbedChunkedFile {
    static func errorOnFileChunkRequest(_ sequenceNum: Int) -> Result<FileChunk, Error> {
        return Result.failure(ChunkedFileError.invalidState("test err"))
    }
    
    static func makeDummyFileChunk(_ sequenceNum: Int) -> Result<FileChunk, Error> {
        var readlen = 100
        let filesize = 1000
        var startByte = sequenceNum * readlen
        var endByte = (sequenceNum * readlen) + readlen
        if endByte >= filesize {
            startByte = filesize
            endByte = filesize
            readlen = 0
        }
        return Result.success(
            FileChunk(
                startByte: UInt64(startByte),
                endByte: UInt64(endByte),
                totalFileSize: UInt64(filesize),
                chunkData: Data(capacity: readlen)
            )
        )
    }
}
