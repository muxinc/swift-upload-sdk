//
//  UploadManager.swift
//  Manages large file uploads in a global context for access by many UI elements
//
//  Created by Emily Dixon on 3/8/23.
//

import Foundation

/// Manages uploads in-progress by the Mux Upload SDK.
/// If your ``MuxUpload`` is managed, you can get a new handle to it using ``getStartedUpload(ofFile:)``
///
/// To create a new upload, use ``MuxUpload``
///
/// Managed uploads can be resumed where they left off after process death, and can be accessed anywhere in your
/// app without needing to manually track the tasks or their state
///
/// Managed uploads only survive process death if they were paused or in progress. Success and failure must be handled
/// by you, even if those events occur during (for instance) a ``BGTask``
///
/// (see ``MuxUpload.Builder.manage(automatically:)``)
public final class UploadManager {
    
    private var uploadersByURL: [URL : ChunkedFileUploader] = [:]
    private var uploadsUpdateDelegatesByToken: [Int : UploadsUpdatedDelegate] = [:]
    private let uploadActor = UploadCacheActor()
    private lazy var uploaderDelegate: FileUploaderDelegate = FileUploaderDelegate(manager: self)
    
    /// Finds an upload already in-progress and returns a new ``MuxUpload`` that can be observed
    /// to track and control its state
    /// Returns nil if there was no uplod in progress for thr given file
    public func findStartedUpload(ofFile url: URL) -> MuxUpload? {
        if let uploader = uploadersByURL[url] {
            return MuxUpload(wrapping: uploader, uploadManager: self)
        } else {
            return nil
        }
    }
    
    /// Returns all uploads currently-managed uploads.
    /// Uploads are managed while in-progress or compelted.
    ///  Uploads become un-managed when canceled, or if the process dies after they complete
    public func allManagedUploads() -> [MuxUpload] {
        return uploadersByURL.compactMap { (key, value) in MuxUpload(wrapping: value, uploadManager: self) }
    }
    
    /// Attempts to resume an upload that was previously paused or interrupted by process death
    ///  If no upload was found in the cache, this method returns null without taking any action
    public func resumeUpload(ofFile: URL) async -> MuxUpload? {
        let fileUploader = await uploadActor.getUpload(ofFileAt: ofFile)
        if let nonNilUploader = fileUploader {
            nonNilUploader.addDelegate(withToken: Int.random(in: Int.min...Int.max), uploaderDelegate)
            return MuxUpload(wrapping: nonNilUploader, uploadManager: self)
        } else {
            return nil
        }
    }
    
    /// Attempts to resume an upload that was previously paused or interrupted by process death
    ///  If no upload was found in the cache, this method returns null without taking any action
    public func resumeUpload(ofFile: URL, completion: @escaping (MuxUpload) -> Void) {
        Task.detached {
            let upload = await self.resumeUpload(ofFile: ofFile)
            if let nonNilUpload = upload {
                await MainActor.run { completion(nonNilUpload) }
            }
        }
    }
    
    /// Resumes all upload that were paused or interrupted
    /// It can be handy to call this in your ``AppDelegate`` to resume uploads that have been killed by the process dying
    public func resumeAllUploads() {
        Task.detached { [self] in
            for upload in await uploadActor.getAllUploads() {
                upload.addDelegate(withToken: Int.random(in: Int.min...Int.max), uploaderDelegate)
            }
        }
    }
    
    /// Adds an ``UploadsUpdatedDelegate`` with the given ID. You can add as many of these as you like, each with a uniqe ID
    public func addUploadsUpdatedDelegate(id: Int, _ delegate: UploadsUpdatedDelegate?) {
        if let delegate = delegate {
            uploadsUpdateDelegatesByToken[id] = delegate
        } else {
            uploadsUpdateDelegatesByToken.removeValue(forKey: id)
        }
    }
    
    /// A delegate that handles changes to the list of active uploads
    public typealias UploadsUpdatedDelegate = ([MuxUpload]) -> Void
    
    internal func acknowledgeUpload(ofFile url: URL) {
        if let uploader = uploadersByURL[url] {
            uploader.cancel()
        }
        uploadersByURL.removeValue(forKey: url)
        Task.detached {
            await self.uploadActor.remove(uploadAt:url)
            self.notifyDelegates()
        }
    }
    
    internal func findUploaderFor(videoFile url: URL) -> ChunkedFileUploader? {
        return uploadersByURL[url]
    }
    
    internal func registerUploader(_ fileWorker: ChunkedFileUploader, withId id: Int) {
        uploadersByURL.updateValue(fileWorker, forKey: fileWorker.uploadInfo.videoFile)
        fileWorker.addDelegate(withToken: id + 1, uploaderDelegate)
        Task.detached {
            await self.uploadActor.updateUpload(
                fileWorker.uploadInfo,
                withUpdate: fileWorker.currentState
            )
            self.notifyDelegates()
        }
    }
    
    private func notifyDelegates() {
        self.uploadsUpdateDelegatesByToken
            .map { it in it.value }
            .forEach { it in it(self.allManagedUploads()) }
    }
    
    /// The shared instance of this object that should be used
    public static let shared = UploadManager()
    private init() { }
    
    private struct FileUploaderDelegate : ChunkedFileUploaderDelegate {
        let manager: UploadManager
        
        func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState) {
            Task.detached {
                await manager.uploadActor.updateUpload(uploader.uploadInfo, withUpdate: state)
                manager.notifyDelegates()
            }
            switch state {
            case .success(_), .canceled, .failure(_): manager.acknowledgeUpload(ofFile: uploader.uploadInfo.videoFile)
            default: do { }
            }
        }
    }
}

/// Isolates/synchronizes multithreaded access to the upload cache.
internal actor UploadCacheActor {
    private let persistence: UploadPersistence
    
    func updateUpload(_ info: UploadInfo, withUpdate update: ChunkedFileUploader.InternalUploadState) async {
        Task {
            persistence.update(uploadState: update, forUpload: info)
        }
    }
    
    func getUpload(ofFileAt url: URL) async -> ChunkedFileUploader? {
        // reminder: doesn't start the uploader, just makes it
        return await Task<ChunkedFileUploader?, Never> {
            let optEntry = try? persistence.readEntry(forFileAt: url)
            guard let entry = optEntry else {
                return nil
            }
            return ChunkedFileUploader(uploadInfo: entry.uploadInfo, startingAtByte: entry.lastSuccessfulByte)
        }.value
    }
    
    func getAllUploads() async -> [ChunkedFileUploader] {
        return await Task<[ChunkedFileUploader]?, Never> {
            return try? persistence.readAll().compactMap { it in
                ChunkedFileUploader(uploadInfo: it.uploadInfo, startingAtByte: it.lastSuccessfulByte)
            }
        }.value ?? []
    }
    
    func remove(uploadAt url: URL) async {
        await Task<(), Never> {
            try? persistence.remove(entryAtAbsUrl: url)
        }.value
    }
    
    init() {
        // This try-assert is safe if the process home dir is writeable (which it is generally)
        self.persistence = try! UploadPersistence()
    }
}
