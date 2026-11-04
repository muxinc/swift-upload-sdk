import Foundation
import CryptoKit

enum UploadRecoveryError: LocalizedError {
    case newUploadRequired
    case payloadChanged
    case invalidAcknowledgement

    var errorDescription: String? {
        switch self {
        case .newUploadRequired: return "Create a new direct upload (new upload URL) from the original file."
        case .payloadChanged: return "The upload payload changed. Create a new direct upload (new upload URL)."
        case .invalidAcknowledgement: return "The upload server returned an invalid acknowledgement."
        }
    }
}

extension Error {
    var uploadCause: Error {
        if let error = self as? InternalUploaderError { return error.reason.uploadCause }
        if let error = self as? ChunkWorker.ChunkWorkerError, let reason = error.reason { return reason.uploadCause }
        if case .fileHandle(let error) = self as? ChunkedFileError { return error.uploadCause }
        return self
    }

    var uploadFileIsMissing: Bool {
        let error = uploadCause as NSError
        return error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
    }

    var uploadRequiresNewURL: Bool {
        let cause = uploadCause
        if uploadFileIsMissing { return true }
        if let error = cause as? UploadRecoveryError {
            switch error { case .newUploadRequired, .payloadChanged: return true; default: return false }
        }
        if let http = cause as? HttpError {
            return (400..<500).contains(http.statusCode) && ![408, 429].contains(http.statusCode)
        }
        return false
    }
}

/// Verify identity at the transport boundary and on resume, never on progress updates.
func uploadPayloadDigest(at url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty {
        try Task.checkCancellation()
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
