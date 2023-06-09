//
//  UploadManager.swift
//  Manages large file uploads in a global context for access by many UI elements
//
//  Created by Emily Dixon on 3/8/23.
//

import Foundation

/// Manages uploads in-progress by the Mux Upload SDK. Uploads are managed globally by default and can be started, paused,
/// or cancelled from anywhere in your app.
///
/// This class is used to find and resume uploads previously-created via ``MuxUpload``. Upload tasks created by ``MuxUpload``
/// are, by defauly globally managed. If your ``MuxUpload`` is managed, you can get a new handle to it anywhere by  using
/// ``findStartedUpload(ofFile:)`` or ``allManagedUploads()``
///
/// ## Handling failure, backgrounding, and process death
/// Managed uploads can be resumed where they left off after process death, and can be accessed anywhere in your
/// app without needing to manually track the tasks or their state. Managed uploads only survive process death if they
/// were paused, in progress, or have failed. Success must be handled by you, even if it occurs, eg, during a `BGTask`
///
/// ```swift
/// // Call during app init
/// UploadManager.resumeAllUploads()
/// let restartedUploads = UploadManager.allManagedUploads()
/// // ... do something with the restrted uploads, like subscribing to progress updates for instance
/// ```
///
public final class UploadManager {
    
    private var uploadersByID: [String : ChunkedFileUploader] = [:]
    private var uploadsUpdateDelegatesByToken: [ObjectIdentifier : any UploadsUpdatedDelegate] = [:]
    private let uploadActor = UploadCacheActor()
    private lazy var uploaderDelegate: FileUploaderDelegate = FileUploaderDelegate(manager: self)
    
    /// Finds an upload already in-progress and returns a new ``MuxUpload`` that can be observed
    /// to track and control its state
    /// Returns nil if there was no uplod in progress for thr given file
    public func findStartedUpload(ofFile url: URL) -> MuxUpload? {
        if let uploader = Dictionary<URL, ChunkedFileUploader>(
            uniqueKeysWithValues: uploadersByID.mapValues { value in
                (value.uploadInfo.videoFile, value)
            }
            .values
        )[url] {
            return MuxUpload(wrapping: uploader, uploadManager: self)
        } else {
            return nil
        }
    }
    
    /// Returns all uploads currently-managed uploads.
    /// Uploads are managed while in-progress or compelted.
    ///  Uploads become un-managed when canceled, or if the process dies after they complete
    public func allManagedUploads() -> [MuxUpload] {
        return uploadersByID.compactMap { (key, value) in MuxUpload(wrapping: value, uploadManager: self) }
    }
    
    /// Attempts to resume an upload that was previously paused or interrupted by process death
    ///  If no upload was found in the cache, this method returns null without taking any action
    public func resumeUpload(ofFile: URL) async -> MuxUpload? {
        let fileUploader = await uploadActor.getUpload(ofFileAt: ofFile)
        if let nonNilUploader = fileUploader {
            nonNilUploader.addDelegate(withToken: UUID().uuidString, uploaderDelegate)
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
    /// It can be useful to call this during app initialization to resume uploads that have been killed by the process dying
    public func resumeAllUploads() {
        Task.detached { [self] in
            for upload in await uploadActor.getAllUploads() {
                upload.addDelegate(withToken: UUID().uuidString, uploaderDelegate)
            }
        }
    }
    
    /// Adds an ``UploadsUpdatedDelegate`` You can add as many of these as you like
    public func addUploadsUpdatedDelegate<Delegate: UploadsUpdatedDelegate>(_ delegate: Delegate) {
        uploadsUpdateDelegatesByToken[ObjectIdentifier(delegate)] = delegate
    }
    
    /// Removes an ``UploadsUpdatedDelegate``
    public func removeUploadsUpdatedDelegate<Delegate: UploadsUpdatedDelegate>(_ delegate: Delegate) {
        uploadsUpdateDelegatesByToken.removeValue(forKey: ObjectIdentifier(delegate))
    }
    
    internal func acknowledgeUpload(id: String) {
        if let uploader = uploadersByID[id] {
            uploader.cancel()
        }
        uploadersByID.removeValue(forKey: id)
        Task.detached {
            await self.uploadActor.remove(uploadID: id)
            self.notifyDelegates()
        }
    }
    
    internal func findUploaderFor(videoFile url: URL) -> ChunkedFileUploader? {
        return Dictionary<URL, ChunkedFileUploader>(
            uniqueKeysWithValues: uploadersByID.mapValues { value in
                (value.uploadInfo.videoFile, value)
            }
            .values
        )[url]
    }

    internal func registerUploader(_ fileWorker: ChunkedFileUploader, withId id: String) {
        uploadersByID.updateValue(fileWorker, forKey: fileWorker.uploadInfo.id)
        fileWorker.addDelegate(withToken: UUID().uuidString, uploaderDelegate)
        Task.detached {
            await self.uploadActor.updateUpload(
                fileWorker.uploadInfo,
                withUpdate: fileWorker.currentState
            )
            self.notifyDelegates()
        }
    }
    
    private func notifyDelegates() {
        Task.detached {
            await MainActor.run {
                self.uploadsUpdateDelegatesByToken
                    .map { it in it.value }
                    .forEach { it in it.uploadListUpdated(with: self.allManagedUploads()) }
                
            }
        }
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
            case .success(_), .canceled: manager.acknowledgeUpload(id: uploader.uploadInfo.id)
            default: do { }
            }
        }
    }
}

/// A delegate that handles changes to the list of active uploads
public protocol UploadsUpdatedDelegate: AnyObject {
    /// Called when the global list of uploads changes. This happens whenever a new upload is started, or an existing one completes or fails
    func uploadListUpdated(with list: [MuxUpload])
}


/// Isolates/synchronizes multithreaded access to the upload cache.
internal actor UploadCacheActor {
    private let persistence: UploadPersistence
    
    func updateUpload(_ info: UploadInfo, withUpdate update: ChunkedFileUploader.InternalUploadState) async {
        Task {
            persistence.update(uploadState: update, forUpload: info)
        }
    }
    
    func getUpload(uploadID: String) async -> ChunkedFileUploader? {
        // reminder: doesn't start the uploader, just makes it
        return await Task<ChunkedFileUploader?, Never> {
            let optEntry = try? persistence.readEntry(uploadID: uploadID)
            guard let entry = optEntry else {
                return nil
            }
            return ChunkedFileUploader(uploadInfo: entry.uploadInfo, startingAtByte: entry.lastSuccessfulByte)
        }.value
    }

    func getUpload(ofFileAt: URL) async -> ChunkedFileUploader? {
        return await Task<ChunkedFileUploader?, Never> {
            guard let matchingEntry = try? persistence.readAll().filter({
                $0.uploadInfo.uploadURL == ofFileAt
            }).first else {
                return nil
            }

            return ChunkedFileUploader(
                uploadInfo: matchingEntry.uploadInfo,
                startingAtByte: matchingEntry.lastSuccessfulByte
            )
        }.value
    }
    
    func getAllUploads() async -> [ChunkedFileUploader] {
        return await Task<[ChunkedFileUploader]?, Never> {
            return try? persistence.readAll().compactMap { it in
                ChunkedFileUploader(uploadInfo: it.uploadInfo, startingAtByte: it.lastSuccessfulByte)
            }
        }.value ?? []
    }
    
    func remove(uploadID: String) async {
        await Task<(), Never> {
            try? persistence.remove(entryAtID: uploadID)
        }.value
    }
    
    init() {
        // This try-assert is safe if the process home dir is writeable (which it is generally)
        self.persistence = try! UploadPersistence()
    }
}
