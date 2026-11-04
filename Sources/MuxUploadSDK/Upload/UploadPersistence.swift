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
    private static let ENTRY_TTL: TimeInterval = 7 * 24 * 60 * 60 // Maximum Mux upload URL lifetime
    
    private let fileURL: URL
    private var cache: [String : PersistenceEntry]? // populated on first write for this object (see ensureCache())
    private let uploadsFile: UploadsFile
    private let outputStorage: FileSystemTemporaryStoragePreflighter?
    
    func update(
        uploadState state: ChunkedFileUploader.InternalUploadState,
        for uploadInfo: UploadInfo,
        fileInputURL: URL
    ) {
        do {
            // If the new state is persistable, persist it (overwriting the old) otherwise delete it
            if let entry = PersistenceEntry.fromUploadState(
                state,
                forUpload: uploadInfo,
                inputFileURL: fileInputURL
            ) {
                let previous = try readEntry(uploadID: uploadInfo.id)
                let digest = previous?.inputFileURL == fileInputURL ? previous?.payloadDigest : nil
                try write(entry: entry.with(payloadDigest: digest, inputFileURL: fileInputURL,
                                           uploadURL: uploadInfo.uploadURL), for: uploadInfo.id)
            } else {
                try remove(entryAtID: uploadInfo.id)
            }
        } catch {
            // This makes a lot of noise on the emulator, but might be worth logging if you're having issues around here
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
        for entry in try readAll() {
            try remove(entryAtID: entry.uploadInfo.id)
        }
    }
    
    func remove(entryAtID id: String) throws {
        try maybeOpenCache()
        if var cache = cache {
            let removed = cache.removeValue(forKey: id)
            // Keep the record and its bytes if disk removal fails.
            try uploadsFile.writeContents(of: UploadsFileContents(mapOf: cache))
            self.cache = cache
            if let removed, !cache.values.contains(where: { $0.inputFileURL == removed.inputFileURL }),
               (outputStorage ?? FileSystemTemporaryStoragePreflighter()).ownsTemporaryOutput(removed.inputFileURL) {
                try? FileManager.default.removeItem(at: removed.inputFileURL)
            }
        }
    }
    
    /// Directly writes entry. Updates are written-through the internal cache to the backing file
    ///  This method does I/O
    func write(entry: PersistenceEntry, for uploadID: String) throws {
        try maybeOpenCache()
        if var cache = cache {
            cache.updateValue(entry, forKey: uploadID)
            try uploadsFile.writeContents(of: UploadsFileContents(mapOf: cache))
            self.cache = cache
        }
        
    }
    
    /// Directly reads a single entry based on the file URL given
    func readEntry(uploadID: String) throws -> PersistenceEntry? {
        try maybeOpenCache()
        if let cache = cache {
            return cache[uploadID]
        } else {
            return nil
        }
    }
    
    func maybeOpenCache() throws {
        if cache == nil {
            try self.uploadsFile.maybeOpenCache()
            let entries = try uploadsFile.readContents().entriesAbsFileUrlToUploadInfo
            self.cache = UploadsFileContents(entries: entries).asDictionary()
            try outputStorage?.removeAbandonedOutputs(referencedBy: entries,
                before: FileSystemTemporaryStoragePreflighter.sessionStart)
            try cleanUpOldEntries() // Obligatory
        }
    }
    
    private func cleanUpOldEntries() throws {
        let allEntries = try readAll()
        let nowish = Date().timeIntervalSince1970
        for entry in allEntries {
            if (nowish - entry.savedAt) > UploadPersistence.ENTRY_TTL {
                try remove(entryAtID: entry.uploadInfo.id)
            }
        }
    }
    
    private func parse(entryJson: String) throws -> PersistenceEntry {
        let entryData = entryJson.data(using: .utf8)!
        return try JSONDecoder().decode(PersistenceEntry.self, from: entryData)
    }
    
    /// Configures and initlaizes an ``UploadPersistence`` for normal production use
    init() throws {
        self.outputStorage = FileSystemTemporaryStoragePreflighter()
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directoryURL = baseDirectory.appendingPathComponent("mux", isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent("uploads-v2.json")
        self.uploadsFile = try UploadsFileImpl(fromFile: fileURL)
    }
    
    /// Allows an UploasdFile to be injected at the given path
    init(innerFile: UploadsFile, atURL url: URL, outputStorage: FileSystemTemporaryStoragePreflighter? = nil) {
        self.outputStorage = outputStorage
        self.uploadsFile = innerFile
        self.fileURL = url
    }
}

/// Flattened version of an upload in progress
struct PersistenceEntry : Codable {
    let savedAt: TimeInterval
    let stateCode: PreviousStateCode
    let lastSuccessfulByte: UInt64
    let uploadInfo: UploadInfo
    let inputFileURL: URL
    var payloadDigest: String? = nil

    private enum CodingKeys: String, CodingKey {
        case savedAt, stateCode, lastSuccessfulByte, uploadInfo, inputFileURL, payloadDigest
        case relativeInputPath, relativeSourcePath
    }

    init(savedAt: TimeInterval, stateCode: PreviousStateCode, lastSuccessfulByte: UInt64,
         uploadInfo: UploadInfo, inputFileURL: URL, payloadDigest: String? = nil) {
        self.savedAt = savedAt; self.stateCode = stateCode; self.lastSuccessfulByte = lastSuccessfulByte
        self.uploadInfo = uploadInfo; self.inputFileURL = inputFileURL; self.payloadDigest = payloadDigest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try values.decode(TimeInterval.self, forKey: .savedAt)
        stateCode = try values.decode(PreviousStateCode.self, forKey: .stateCode)
        lastSuccessfulByte = try values.decode(UInt64.self, forKey: .lastSuccessfulByte)
        var info = try values.decode(UploadInfo.self, forKey: .uploadInfo)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let path = try values.decodeIfPresent(String.self, forKey: .relativeSourcePath) {
            info.sourceFileURL = home.appendingPathComponent(path)
        }
        uploadInfo = info
        if let path = try values.decodeIfPresent(String.self, forKey: .relativeInputPath) {
            inputFileURL = home.appendingPathComponent(path)
        } else { inputFileURL = try values.decode(URL.self, forKey: .inputFileURL) }
        payloadDigest = try values.decodeIfPresent(String.self, forKey: .payloadDigest)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(savedAt, forKey: .savedAt)
        try values.encode(stateCode, forKey: .stateCode)
        try values.encode(lastSuccessfulByte, forKey: .lastSuccessfulByte)
        try values.encode(uploadInfo, forKey: .uploadInfo)
        try values.encode(inputFileURL, forKey: .inputFileURL)
        try values.encodeIfPresent(payloadDigest, forKey: .payloadDigest)
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        func relative(_ url: URL?) -> String? {
            guard let url, url.isFileURL else { return nil }
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(home) ? String(path.dropFirst(home.count)) : nil
        }
        try values.encodeIfPresent(relative(inputFileURL), forKey: .relativeInputPath)
        try values.encodeIfPresent(relative(uploadInfo.sourceFileURL), forKey: .relativeSourcePath)
    }

    enum PreviousStateCode : Int, Codable {
        case wasInProgress = 0, wasPaused = 1, preparing = 2
    }
    
    func with(
        savedAt: TimeInterval? = nil,
        stateCode: PreviousStateCode? = nil,
        lastSuccessfulByte: UInt64? = nil,
        uploadInfo: UploadInfo? = nil,
        payloadDigest: String? = nil,
        inputFileURL: URL,
        uploadURL: URL
    ) -> PersistenceEntry {
        return PersistenceEntry(
            savedAt: savedAt ?? self.savedAt,
            stateCode: stateCode ?? self.stateCode,
            lastSuccessfulByte: lastSuccessfulByte ?? self.lastSuccessfulByte,
            uploadInfo: uploadInfo ?? self.uploadInfo,
            inputFileURL: inputFileURL,
            payloadDigest: payloadDigest ?? self.payloadDigest
        )
    }

    static func fromUploadState(
        _ state: ChunkedFileUploader.InternalUploadState,
        forUpload upload: UploadInfo,
        inputFileURL: URL
    ) -> PersistenceEntry? {
        switch state {
            // Cases that aren't stored also aren't parsed
        case .success(_), .canceled: return nil
        case .failure(let error):
            guard let uploadError = error as? InternalUploaderError,
                  !uploadError.uploadRequiresNewURL else { return nil }
            return PersistenceEntry(
                savedAt: Date().timeIntervalSince1970,
                stateCode: .wasInProgress,
                lastSuccessfulByte: uploadError.lastByte,
                uploadInfo: upload,
                inputFileURL: inputFileURL
            )
            // Can start again but from the beginning
        case .starting, .ready: return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasInProgress,
            lastSuccessfulByte: 0,
            uploadInfo: upload,
            inputFileURL: inputFileURL
        )
        case .paused(let update): return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasPaused,
            lastSuccessfulByte: UInt64(update.progress.completedUnitCount),
            uploadInfo: upload,
            inputFileURL: inputFileURL
        )
        case .uploading(let update): return PersistenceEntry(
            savedAt: Date().timeIntervalSince1970,
            stateCode: .wasInProgress,
            lastSuccessfulByte: UInt64(update.progress.completedUnitCount),
            uploadInfo: upload,
            inputFileURL: inputFileURL
        )
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
    
    func asDictionary() -> [String : PersistenceEntry] {
        return entriesAbsFileUrlToUploadInfo.reduce(into: [:]) { (map, ent) -> () in
            map.updateValue(ent, forKey: ent.uploadInfo.id)
        }
    }
    
    init(entries: [PersistenceEntry]) {
        self.entriesAbsFileUrlToUploadInfo = entries
    }
    
    init(mapOf items: [String : PersistenceEntry]) {
        self.entriesAbsFileUrlToUploadInfo = items.compactMap({ (key, value) in value })
    }
}

/// A JSON file containing the list of available uploads. Can be written or read all at once.
/// Doesn't hold onto read or witten data other than writing or reading the file
struct UploadsFileImpl : UploadsFile {
    
    private let fileURL: URL
    
    func maybeOpenCache() throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        }
        var directory = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func writeContents(of jsonData: UploadsFileContents) throws {
        let data = try JSONEncoder().encode(jsonData)
        try data.write(to: fileURL, options: .atomic)
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
