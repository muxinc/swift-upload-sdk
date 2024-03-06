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

    private struct State {
        var fileHandle: FileHandle
        var fileURL: URL
        var filePosition: UInt64 = 0
    }

    private let chunkSize: Int

    var fileManager = FileManager.default

    private var state: State?

    private var fileHandle: FileHandle? {
        state?.fileHandle
    }
    private var fileURL: URL? {
        state?.fileURL
    }
    private var filePos: UInt64 {
        state?.filePosition ?? 0
    }
    
    /// Reads the next chunk from the file, advancing the file for the next read
    ///  This method does synchronous I/O, so call it in the background
    func readNextChunk() -> Result<FileChunk, Error> {
        SDKLogger.logger?.info("--readNextChunk(): called")
        do {
            guard let fileHandle else {
                return Result.failure(ChunkedFileError.invalidState("readNextChunk() called but the file was not open"))
            }

            guard let fileURL = fileURL else {
                return Result.failure(ChunkedFileError.invalidState("Missing file url."))
            }
            var data : Data?
            try autoreleasepool {
                data = try fileHandle.read(upToCount: chunkSize)
            }

            let fileSize = try fileManager.fileSizeOfItem(
                atPath: fileURL.path
            )

            guard let data = data else {
                // Called while already at the end of the file. We read zero bytes, "ending" at the end of the file
                return .success(
                    FileChunk(
                        startByte: fileSize,
                        endByte: fileSize,
                        totalFileSize: fileSize,
                        chunkData: Data(capacity: 0)
                    )
                )
            }

            let chunkLength = data.count
            let updatedFilePosition = filePos + UInt64(chunkLength)

            let chunk = FileChunk(
                startByte: self.filePos,
                endByte: updatedFilePosition,
                totalFileSize: fileSize,
                chunkData: data
            )

            state?.filePosition = updatedFilePosition

            return .success(chunk)
        } catch {
            return Result.failure(ChunkedFileError.fileHandle(error))
        }
    }

    /// Opens the internal file ahead of time. Calling this is optional, but it's available
    /// Calling this multiple times (on the same thread) will have no effect unless you also ``close`` it
    /// Throws if the file couldn't be opened
    func openFile(fileURL: URL) throws {
        if state == nil {
            do {
                let fileSize = try fileManager.fileSizeOfItem(atPath: fileURL.path)
                let fileHandle = try FileHandle(forReadingFrom: fileURL)
                state = State(
                    fileHandle: fileHandle,
                    fileURL: fileURL
                )
                SDKLogger.logger?.info("Opened file with len \(String(describing: fileSize)) at path \(fileURL.path)")
            } catch {
                throw ChunkedFileError.fileHandle(error)
            }
        }
    }
    
    /// Closes the the file opened by ``openFile``. Should be called on the same thread that opened the file
    ///  Calling this multiple times has no effect
    func close() {
        do {
            try fileHandle?.close()
        } catch {
            SDKLogger.logger?.warning("Swallowed error closing file: \(error.localizedDescription)")
        }
        state = nil
    }
    
    func seekTo(byte: UInt64) throws {
        // Worst case: we start from the begining and there's a few very quick chunk successes
        try fileHandle?.seek(toOffset: byte)
        state?.filePosition = byte
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
