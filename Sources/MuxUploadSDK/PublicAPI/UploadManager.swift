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
/// This class is used to find and resume uploads previously-created via ``DirectUpload``. Upload tasks created by ``DirectUpload``
/// are, by defauly globally managed. If your ``DirectUpload`` is managed, you can get a new handle to it anywhere by  using
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

    private struct UploadStorage: Equatable, Hashable {
        let upload: DirectUpload

        static func == (lhs: UploadManager.UploadStorage, rhs: UploadManager.UploadStorage) -> Bool {
            ObjectIdentifier(
                lhs.upload
            ) == ObjectIdentifier(
                rhs.upload
            )
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(upload))
        }
    }
    
    private var uploadsByID: [String : UploadStorage] = [:]
    private var uploadsUpdateDelegatesByToken: [ObjectIdentifier : any UploadsUpdatedDelegate] = [:]
    private let uploadActor = UploadCacheActor()
    private lazy var uploaderDelegate: FileUploaderDelegate = FileUploaderDelegate(manager: self)
    
    /// Finds an upload already in-progress and returns a new ``DirectUpload`` that can be observed
    /// to track and control its state
    /// Returns nil if there was no uplod in progress for thr given file
    public func findStartedUpload(ofFile url: URL) -> DirectUpload? {
        for upload in uploadsByID.values.map(\.upload) {
            if upload.videoFile == url {
                return upload
            }
        }

        return nil
    }
    
    /// Returns all uploads currently-managed uploads.
    /// Uploads are managed while in-progress or compelted.
    ///  Uploads become un-managed when canceled, or if the process dies after they complete
    public func allManagedUploads() -> [DirectUpload] {
        // Sort upload list for consistent ordering
        return Array(uploadsByID.values.map(\.upload))
    }
    
    /// Attempts to resume an upload that was previously paused or interrupted by process death
    ///  If no upload was found in the cache, this method returns null without taking any action
    public func resumeUpload(ofFile: URL) async -> DirectUpload? {
        let fileUploader = await uploadActor.getUpload(ofFileAt: ofFile)
        if let nonNilUploader = fileUploader {
            nonNilUploader.addDelegate(withToken: UUID().uuidString, uploaderDelegate)
            return DirectUpload(wrapping: nonNilUploader, uploadManager: self)
        } else {
            return nil
        }
    }
    
    /// Attempts to resume an upload that was previously paused or interrupted by process death
    ///  If no upload was found in the cache, this method returns null without taking any action
    public func resumeUpload(ofFile: URL, completion: @escaping (DirectUpload) -> Void) {
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
        if let upload = uploadsByID[id]?.upload {
            uploadsByID.removeValue(forKey: id)
            upload.fileWorker?.cancel()
        }
        Task.detached {
            await self.uploadActor.remove(uploadID: id)
            self.notifyDelegates()
        }
    }
    
    internal func findChunkedFileUploader(
        inputFileURL: URL
    ) -> ChunkedFileUploader? {
        findStartedUpload(
            ofFile: inputFileURL
        )?.fileWorker
    }

    internal func registerUpload(_ upload: DirectUpload) {

        guard let fileWorker = upload.fileWorker else {
            // Only started uploads, aka uploads with a file
            // worker can be registered.
            // TODO: Should this throw?
            MuxUploadSDK.logger?.debug("registerUpload() called for an unstarted upload")
            return
        }

        uploadsByID.updateValue(UploadStorage(upload: upload), forKey: upload.id)
        fileWorker.addDelegate(withToken: UUID().uuidString, uploaderDelegate)
        Task.detached {
            await self.uploadActor.updateUpload(
                fileWorker.uploadInfo,
                fileInputURL: fileWorker.inputFileURL,
                withUpdate: fileWorker.currentState
            )
            self.notifyDelegates()
        }
    }
    
    private func notifyDelegates() {
        Task.detached {
            await MainActor.run {
                let delegates = self.uploadsUpdateDelegatesByToken.values
                let allManagedUploads = self.allManagedUploads()

                for delegate in delegates {
                    delegate.uploadListUpdated(with: allManagedUploads)
                }
            }
        }
    }
    
    /// The shared instance of this object that should be used
    public static let shared = UploadManager()
    internal init() { }
    
    private struct FileUploaderDelegate : ChunkedFileUploaderDelegate {
        let manager: UploadManager
        
        func chunkedFileUploader(_ uploader: ChunkedFileUploader, stateUpdated state: ChunkedFileUploader.InternalUploadState) {
            Task.detached {
                await manager.uploadActor.updateUpload(
                    uploader.uploadInfo,
                    fileInputURL: uploader.inputFileURL,
                    withUpdate: state
                )
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
    func uploadListUpdated(with list: [DirectUpload])
}


/// Isolates/synchronizes multithreaded access to the upload cache.
internal actor UploadCacheActor {
    private let persistence: UploadPersistence
    
    func updateUpload(
        _ uploadInfo: UploadInfo,
        fileInputURL: URL,
        withUpdate update: ChunkedFileUploader.InternalUploadState
    ) async {
        Task {
            persistence.update(
                uploadState: update,
                for: uploadInfo,
                fileInputURL: fileInputURL
            )
        }
    }
    
    func getUpload(uploadID: String) async -> ChunkedFileUploader? {
        // reminder: doesn't start the uploader, just makes it
        return await Task<ChunkedFileUploader?, Never> {
            try? persistence
                .readEntry(uploadID: uploadID)
                .map({ entry in
                    return ChunkedFileUploader(
                        persistenceEntry: entry
                    )
                })
        }.value
    }

    func getUpload(ofFileAt: URL) async -> ChunkedFileUploader? {
        return await Task<ChunkedFileUploader?, Never> {
            guard let matchingEntry = try? persistence.readAll().first(
                where: { $0.uploadInfo.uploadURL == ofFileAt }
            ) else {
                return nil
            }

            return ChunkedFileUploader(
                persistenceEntry: matchingEntry
            )
        }.value
    }
    
    func getAllUploads() async -> [ChunkedFileUploader] {
        return await Task<[ChunkedFileUploader]?, Never> {
            return try? persistence.readAll().compactMap { it in
                ChunkedFileUploader(
                    persistenceEntry: it
                )
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
