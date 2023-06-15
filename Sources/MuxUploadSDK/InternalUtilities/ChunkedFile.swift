//
//  ChunkedFile.swift
//  Splits a file into chunks of a given size, plus one extra for the remainder of the file
//
//  Created by Emily Dixon on 2/22/23.
//

import Foundation

/// Represents a file split into chunks based on a given chunk size
/// This object does synchronous work requiring a background thread and it is *not* thread-safe.
/// Callers must dispatch its output as needed, and should not allow access to this object from off their worker thread.
/// Buffers are allocated for each new chunk so they can safely escape to other threads
/// Call  ``close`` when you're done with this object
class ChunkedFile {
    
    static let SIZE_UNKNOWN: UInt64 = 0
    /// The size of the file. Call ``open`` to populate this with a real value, otherwise it will be ``SIZE_UNKNOWN``
    var fileSize: UInt64 {
        return _fileSize
    }
    
    private let chunkSize: Int
    
    private var fileHandle: FileHandle?
    private var filePos: UInt64 = 0
    private var _fileSize: UInt64 = SIZE_UNKNOWN
    
    /// Reads the next chunk from the file, advancing the file for the next read
    ///  This method does synchronous I/O, so call it in the background
    func readNextChunk() -> Result<FileChunk, Error> {
        MuxUploadSDK.logger?.info("--readNextChunk(): called")
        do {
            guard fileHandle != nil else {
                return Result.failure(ChunkedFileError.invalidState("readNextChunk() called but the file was not open"))
            }
            return try Result.success(doReadNextChunk())
        } catch {
            return Result.failure(ChunkedFileError.fileHandle(error))
        }
    }
    
    /// Opens the internal file ahead of time. Calling this is optional, but it's available
    /// Calling this multiple times (on the same thread) will have no effect unless you also ``close`` it
    /// Throws if the file couldn't be opened
    public func openFile(fileURL: URL) throws {
        if fileHandle == nil {
            do {
                guard let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[FileAttributeKey.size] as? UInt64 else {
                    throw ChunkedFileError.invalidState("Cannot retrieve file size")
                }
                self._fileSize = fileSize
                
                let handle = try FileHandle(forReadingFrom: fileURL)
                fileHandle = handle
                MuxUploadSDK.logger?.info("Opened file with len \(String(describing: fileSize)) at path \(fileURL.path)")
            } catch {
                throw ChunkedFileError.fileHandle(error)
            }
        }
    }
    
    /// Closes the the file opened by ``openFile``. Should be called on the same thread that opened the file
    ///  Calling this multiple times has no effect
    public func close() {
        do {
            try fileHandle?.close()
        } catch {
            MuxUploadSDK.logger?.warning("Swallowed error closing file: \(error.localizedDescription)")
        }
        fileHandle = nil
        filePos = 0
        _fileSize = ChunkedFile.SIZE_UNKNOWN
    }
    
    public func seekTo(byte: UInt64) throws {
        // Worst case: we start from the begining and there's a few very quick chunk successes
        try fileHandle?.seek(toOffset: byte)
        filePos = byte
    }
    
    private func doReadNextChunk() throws -> FileChunk {
        MuxUploadSDK.logger?.info("--doReadNextChunk")
        guard let fileHandle = fileHandle else {
            throw ChunkedFileError.invalidState("doReadNextChunk called without file handle. Did you call open()?")
        }
        let data = try fileHandle.read(upToCount: chunkSize)
        guard let data = data else {
            // Called while already at the end of the file. We read zero bytes, "ending" at the end of the file
            return FileChunk(startByte: fileSize, endByte: fileSize, totalFileSize: fileSize, chunkData: Data(capacity: 0))
        }
        
        let nsData = NSData(data: data)
        let readLen = nsData.length
        let newFilePos = filePos + UInt64(readLen)
        let chunk = FileChunk(
            startByte: self.filePos,
            endByte: newFilePos,
            totalFileSize: fileSize,
            chunkData: data
        )
        
        self.filePos = newFilePos
        
        return chunk
    }
    
    /// Creates a ``ChunkedFile`` that wraps the file given by the URL. The file will be opened after  calling ``openFile()``
    init(chunkSize: Int) {
        self.chunkSize = chunkSize
    }
}

/// A chunk of data read from a ``ChunkedFile``. The ``Data`` in this struct is heap-allocated and based on
///    the chunk size that the user requested. It is probably less than 2M
struct FileChunk {
    /// Inclusive
    let startByte: UInt64
    /// Exclusive
    let endByte: UInt64
    let totalFileSize: UInt64
    let chunkData: Data
    
    func size() -> Int {
        return Int(endByte - startByte) // This is safe for any reasonable chunk size
    }
}

enum ChunkedFileError : Error {
    case invalidState(String)
    case fileHandle(Error)
    
    var localizedDescription: String {
        get {
            switch self {
            case .invalidState(let msg): return msg
            case .fileHandle(let err): return "Couldn't read file for upload due to:\n\t\(err.localizedDescription)"
            }
        }
    }
}
