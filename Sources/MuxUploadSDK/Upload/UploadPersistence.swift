//
//  UploadPersistence.swift
//  
//
//  Created by Emily Dixon on 3/6/23.
//

import Foundation

/// Persists in-progress uploads to disk for up to a few days.
///  This class is structured like a write-through cache, and it expects that there will only be one object
///  of its type in the process (inside MuxUploadManager).
///  It is not thread-safe
class UploadPersistence {
    private static let ENTRY_TTL: TimeInterval = 3 * 24 * 60 * 60 // 3 days
    
    private let fileURL: URL
    private var cache: [URL : PersistenceEntry]? // populated on first write for this object (see ensureCache())
    private let uploadsFile: UploadsFile
    
    func update(uploadState state: ChunkedFileUploader.InternalUploadState, forUpload upload: UploadInfo) {
        do {
            // If the new state is persistable, persist it (overwriting the old) otherwise delete it
            if let entry = PersistenceEntry.fromUploadState(state, forUpload: upload) {
                try write(entry: entry, forFileAt: upload.videoFile)
            } else {
                try remove(entryAtAbsUrl: upload.uploadURL)
            }
        } catch {
            //MuxUploadSDK.logger?.critical("Swallowed error writing to UploadPersistence! Error below:\n\(error.localizedDescription)")
        }
    }
    
    /// Reads all entries out of persistence. Will return cached data if available
    func readAll() throws -> [PersistenceEntry] {
        try maybeOpenCache()
        return cache!.compactMap { (key, value) in value }
    }
    
    func clear() throws {
        try maybeOpenCache()
        if var cache = cache {
            cache.removeAll()
            try uploadsFile.writeContents(of: UploadsFileContents(mapOf: cache))
        }
    }
    
    func remove(entryAtAbsUrl url: URL) throws {
        try maybeOpenCache()
        if var cache = cache {
            cache.removeValue(forKey: url)
            self.cache = cache
            // write-through
            try uploadsFile.writeContents(of: UploadsFileContents(mapOf: cache))
        }
    }
    
    /// Directly writes entry. Updates are written-through the internal cache to the backing file
    ///  This method does I/O
    func write(entry: PersistenceEntry, forFileAt fileUrl: URL) throws {
        try maybeOpenCache()
        if var cache = cache {
            cache.updateValue(entry, forKey: fileUrl)
            self.cache = cache
            try uploadsFile.writeContents(
                of: UploadsFileContents(entries: cache.map { (key, value) in value })
            )
        }
        
    }
    
    /// Directly reads a single entry based on the file URL given
    func readEntry(forFileAt fileUrl: URL) throws -> PersistenceEntry? {
        try maybeOpenCache()
        if let cache = cache {
            return cache[fileUrl.absoluteURL]
        } else {
            return nil
        }
    }
    
    func maybeOpenCache() throws {
        if cache == nil {
            //MuxUploadSDK.logger?.info("Had to populate write-through cache")
            
            try self.uploadsFile.maybeOpenCache()
            self.cache = try uploadsFile.readContents().asDictionary()
            try cleanUpOldEntries() // Obligatory
        }
    }
    
    private func cleanUpOldEntries() throws {
        let allEntries = try readAll()
        let nowish = Date().timeIntervalSince1970
        for entry in allEntries {
            if (nowish - entry.savedAt) > UploadPersistence.ENTRY_TTL {
                try remove(entryAtAbsUrl: entry.uploadInfo.videoFile)
            }
        }
    }
    
    private func parse(entryJson: String) throws -> PersistenceEntry {
        let entryData = entryJson.data(using: .utf8)!
        return try JSONDecoder().decode(PersistenceEntry.self, from: entryData)
    }
    
    /// Configures and initlaizes an ``UploadPersistence`` for normal production use
    init() throws {
        let dirpath = FileManager.default.currentDirectoryPath + "/mux"
        self.fileURL = URL(string: "file:/\(dirpath)/uploads.json")!
        self.uploadsFile = try UploadsFileImpl(fromFile: fileURL)
    }
    
    /// Allows an UploasdFile to be injected at the given path
    init(innerFile: UploadsFile, atURL url: URL) {
        self.uploadsFile = innerFile
        self.fileURL = url
    }
}

/// Flattened version of an upload in progress
struct PersistenceEntry : Codable {
    let savedAt: TimeInterval
    let stateCode: StoredState
    let lastSuccessfulByte: UInt64
    let uploadInfo: UploadInfo
    
    enum StoredState : Int, Codable { case was_in_progress = 0, was_paused = 1 }
    
    func with(
        savedAt: TimeInterval? = nil,
        stateCode: StoredState? = nil,
        lastSuccessfulByte: UInt64? = nil,
        uploadInfo: UploadInfo? = nil
    ) -> PersistenceEntry {
        return PersistenceEntry(
            savedAt: savedAt ?? self.savedAt,
            stateCode: stateCode ?? self.stateCode,
            lastSuccessfulByte: lastSuccessfulByte ?? self.lastSuccessfulByte,
            uploadInfo: uploadInfo ?? self.uploadInfo
        )
    }
    
    static func fromUploadState(_ state: ChunkedFileUploader.InternalUploadState, forUpload upload: UploadInfo) -> PersistenceEntry? {
        switch state {
            // Cases that aren't stored also aren't parsed
        case .success(_), .canceled, .failure(_): return nil
            // Can start again but from the beginning
        case .starting, .ready: return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .was_in_progress,
            lastSuccessfulByte: 0,
            uploadInfo: upload
        )
        case .paused(let update): return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .was_paused,
            lastSuccessfulByte: UInt64(update.progress.completedUnitCount),
            uploadInfo: upload
        )
        case .uploading(let update): return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .was_in_progress,
            lastSuccessfulByte: UInt64(update.progress.completedUnitCount),
            uploadInfo: upload
        )
//        case .failure(let error): return PersistenceEntry(
//            savedAt: Date().timeIntervalSince1970,
//            stateCode: .was_in_progress,
//            lastSuccessfulByte: (error as? InternalUploaderError)?.lastByte ?? 0,
//            uploadInfo: upload
//        )
        }
    }
}

protocol UploadsFile {
    func writeContents(of jsonData: UploadsFileContents) throws
    func readContents() throws -> UploadsFileContents
    func maybeOpenCache() throws
}

struct UploadsFileContents : Codable {
    let entriesAbsFileUrlToUploadInfo: [PersistenceEntry]
    
    func asDictionary() -> [URL : PersistenceEntry] {
        return entriesAbsFileUrlToUploadInfo.reduce(into: [:]) { (map, ent) -> () in
            map.updateValue(ent, forKey: ent.uploadInfo.videoFile)
        }
    }
    
    init(entries: [PersistenceEntry]) {
        self.entriesAbsFileUrlToUploadInfo = entries
    }
    
    init(mapOf items: [URL : PersistenceEntry]) {
        self.entriesAbsFileUrlToUploadInfo = items.compactMap({ (key, value) in value })
    }
}

/// A JSON file containing the list of available uploads. Can be written or read all at once.
/// Doesn't hold onto read or witten data other than writing or reading the file
fileprivate struct UploadsFileImpl : UploadsFile {
    
    private let fileURL: URL
    
    func maybeOpenCache() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            //MuxUploadSDK.logger?.info("Had to create temp dir")
            try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        }
        
    }
    
    func writeContents(of jsonData: UploadsFileContents) throws {
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        let data = try JSONEncoder().encode(jsonData)
        try fileHandle.write(contentsOf: data)
        try fileHandle.close()
    }
    
    func readContents() throws -> UploadsFileContents {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return UploadsFileContents(entries: [])
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        let json = try JSONDecoder().decode(UploadsFileContents.self, from: fileHandle.availableData)
        try fileHandle.close()
        return json
    }
    
    init(fromFile fileURL: URL) throws {
        self.fileURL = fileURL
    }
}
