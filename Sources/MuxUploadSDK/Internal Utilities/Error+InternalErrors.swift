//
//  Error+InternalErrors.swift
//  
//
//  Created by Emily Dixon on 2/27/23.
//

import Foundation

/// Extension on Error that allows us to cast ``Error`` as known error that can be thrown internally
extension Error {
    func asChunkedFileError() -> ChunkedFileError? {
        return self as? ChunkedFileError
    }
    
    func asChunkWorkerError() -> ChunkWorker.ChunkWorkerError? {
        return self as? ChunkWorker.ChunkWorkerError
    }
    
    func asInternalUploaderError() -> InternalUploaderError? {
        return self as? InternalUploaderError
    }
    
    func asHttpError() -> HttpError? {
        return self as? HttpError
    }
    
    func asCancellationError() -> CancellationError? {
        return self as? CancellationError
    }
}
