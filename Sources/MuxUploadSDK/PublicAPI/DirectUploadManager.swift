//
//  DirectUploadManager.swift
//  Manages large file uploads in a global context for access by many UI elements
//
//  Created by Emily Dixon on 3/8/23.
//

import Foundation

/// Manages uploads in progress by the Mux Upload SDK. Uploads are managed globally by default and can be started, paused,
/// or canceled from anywhere in your app.
///
/// This class is used to find and resume uploads previously created via ``DirectUpload``. Upload tasks created by ``DirectUpload``
/// are globally managed by default. If your ``DirectUpload`` is managed, you can get a new handle to it anywhere by using
/// ``startedDirectUpload(ofFile:)`` or ``allManagedDirectUploads()``.
///
/// ## Handling failure, backgrounding, and process death
/// Managed uploads can be resumed where they left off after process death, and can be accessed anywhere in your
/// app without needing to manually track the tasks or their state. Managed uploads only survive process death if they
/// were paused, in progress, or failed. Success must be handled by you, even if it occurs, for example, during a `BGTask`.
///
/// ```swift
/// // Register a DirectUploadManagerDelegate during app init.
/// // Observe restored uploads in its didUpdate(managedDirectUploads:) callback.
/// DirectUploadManager.shared.resumeAllDirectUploads()
/// ```
///
public final class DirectUploadManager {

    private struct UploadStorage: Equatable, Hashable {
        let upload: DirectUpload
        let worker: ChunkedFileUploader
        var workerState: WorkerState = .available

        enum WorkerState {
            case available, failed, finished
        }

        static func == (lhs: DirectUploadManager.UploadStorage, rhs: DirectUploadManager.UploadStorage) -> Bool {
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

    private struct NotificationSnapshot {
        let delegates: [any DirectUploadManagerDelegate]
        let uploads: [DirectUpload]
    }

    /// Owns the manager's shared in-memory state and makes synchronized access
    /// the only available access. The lock is not recursive, so methods return
    /// snapshots and never call upload workers or delegates while holding it.
    private final class LockedStorage {
        private let lock = NSLock()
        private var _unsafeUploadsByID: [String: UploadStorage] = [:]
        private var _unsafeDelegatesByToken: [ObjectIdentifier: any DirectUploadManagerDelegate] = [:]
        // Retained for this manager's lifetime so even an old cache snapshot
        // cannot restore an acknowledged upload. Explicit registration permits a restart.
        private var _unsafeAcknowledgedIDs: Set<String> = []
        private var _unsafePersistenceTask: Task<Void, Never>?

        func upload(ofFile url: URL) -> DirectUpload? {
            allUploads().first { $0.videoFile == url }
        }

        func allUploads() -> [DirectUpload] {
            withLock {
                Array(_unsafeUploadsByID.values.map(\.upload))
            }
        }

        func upload(forID id: String) -> DirectUpload? {
            withLock {
                guard let stored = _unsafeUploadsByID[id], stored.workerState != .failed else { return nil }
                return stored.upload
            }
        }

        func uploader(inputFileURL: URL, uploadURL: URL) -> ChunkedFileUploader? {
            withLock {
                _unsafeUploadsByID.values.first {
                    $0.workerState == .available && $0.worker.inputFileURL == inputFileURL
                        && $0.worker.uploadInfo.uploadURL == uploadURL
                }?.worker
            }
        }

        func insert(_ upload: DirectUpload, worker: ChunkedFileUploader, persistence: @escaping () async -> Void) {
            withLock {
                _unsafeAcknowledgedIDs.remove(upload.id)
                _unsafeUploadsByID[upload.id] = UploadStorage(upload: upload, worker: worker)
                enqueuePersistence(persistence)
            }
        }

        func restore(_ upload: DirectUpload, worker: ChunkedFileUploader) -> DirectUpload? {
            withLock {
                guard !_unsafeAcknowledgedIDs.contains(upload.id) else { return nil }
                if let existing = _unsafeUploadsByID[upload.id], existing.workerState != .failed {
                    return existing.upload
                }
                _unsafeUploadsByID[upload.id] = UploadStorage(upload: upload, worker: worker)
                return upload
            }
        }

        func recordState(
            of worker: ChunkedFileUploader,
            state: ChunkedFileUploader.InternalUploadState,
            persistence: @escaping () async -> Void
        ) {
            withLock {
                let id = worker.uploadInfo.id
                guard var stored = _unsafeUploadsByID[id], stored.worker === worker,
                      stored.workerState == .available else { return }
                switch state {
                case .failure: stored.workerState = .failed
                case .success: stored.workerState = .finished
                default: break
                }
                _unsafeUploadsByID[id] = stored
                enqueuePersistence(persistence)
            }
        }

        func removeUpload(
            forID id: String,
            matching worker: ChunkedFileUploader?,
            persistence: @escaping () async -> Void
        ) -> DirectUpload? {
            withLock {
                if let worker, _unsafeUploadsByID[id]?.worker !== worker { return nil }
                _unsafeAcknowledgedIDs.insert(id)
                enqueuePersistence(persistence)
                return _unsafeUploadsByID.removeValue(forKey: id)?.upload
            }
        }

        func pendingPersistenceTask() -> Task<Void, Never>? {
            withLock { _unsafePersistenceTask }
        }

        // Called only while locked. Disk operations run asynchronously and in
        // observation order, so an earlier progress save cannot follow a deletion.
        private func enqueuePersistence(_ operation: @escaping () async -> Void) {
            let previous = _unsafePersistenceTask
            _unsafePersistenceTask = Task.detached {
                await previous?.value
                await operation()
            }
        }

        func addDelegate(_ delegate: any DirectUploadManagerDelegate) {
            withLock {
                _unsafeDelegatesByToken[ObjectIdentifier(delegate)] = delegate
            }
        }

        func removeDelegate(_ delegate: any DirectUploadManagerDelegate) {
            withLock {
                _unsafeDelegatesByToken.removeValue(
                    forKey: ObjectIdentifier(delegate)
                )
            }
        }

        func notificationSnapshot() -> NotificationSnapshot {
            withLock {
                NotificationSnapshot(
                    delegates: Array(_unsafeDelegatesByToken.values),
                    uploads: Array(_unsafeUploadsByID.values.map(\.upload))
                )
            }
        }

        /// Synchronous on purpose. Taking a lock directly in an `async`
        /// function risks suspending while holding it, which Swift 6 rejects.
        @discardableResult
        private func withLock<T>(_ body: () -> T) -> T {
            lock.withLock(body)
        }
    }

    private let storage = LockedStorage()
    private let uploadActor: UploadCacheActor

    /// A function makes it explicit that every call creates a new value. A
    /// shared `lazy var` would be unsafe because lazy initialization is not
    /// atomic.
    private func makeUploaderDelegate() -> FileUploaderDelegate {
        FileUploaderDelegate(manager: self)
    }

    init(uploadActor: UploadCacheActor = UploadCacheActor()) {
        self.uploadActor = uploadActor
    }
    
    /// Finds an upload already in progress and returns a new ``DirectUpload`` that can be observed
    /// to track and control its state.
    /// Returns nil if there was no upload in progress for the given file.
    public func startedDirectUpload(ofFile url: URL) -> DirectUpload? {
        storage.upload(ofFile: url)
    }
    
    /// Returns all currently-managed uploads that are
    /// in-progress or completed. Uploads that are canceled
    /// or uploads that completed before the most recent
    /// application termination are omitted.
    public func allManagedDirectUploads() -> [DirectUpload] {
        storage.allUploads()
    }

    /// Attempts to resume an upload that was previously paused, failed, or interrupted by process death.
    /// If no upload was found in the cache, this method returns nil without taking any action.
    public func resumeDirectUpload(ofFile url: URL) async -> DirectUpload? {
        await storage.pendingPersistenceTask()?.value
        guard let uploader = await uploadActor.getUpload(ofFileAt: url),
              let upload = restorePersistedUpload(uploader) else { return nil }
        notifyDelegates()
        return upload
    }
    
    /// Attempts to resume an upload that was previously paused, failed, or interrupted by process death.
    /// If no upload was found in the cache, this method returns nil without taking any action.
    public func resumeDirectUpload(ofFile url: URL, completion: @escaping (DirectUpload) -> Void) {
        Task.detached {
            let upload = await self.resumeDirectUpload(ofFile: url)
            if let nonNilUpload = upload {
                await MainActor.run { completion(nonNilUpload) }
            }
        }
    }
    
    /// Restores all uploads that were paused, interrupted, or failed, retaining live handles already managed by this instance.
    /// Restoration is asynchronous. Register a ``DirectUploadManagerDelegate`` before calling this method to receive
    /// the restored list on the main thread, including an empty list when there are no uploads to restore.
    /// Call ``DirectUpload/start(forceRestart:)`` on a restored upload to continue its transfer.
    public func resumeAllDirectUploads() {
        Task.detached { [self] in
            await storage.pendingPersistenceTask()?.value
            for uploader in await uploadActor.getAllUploads() {
                _ = restorePersistedUpload(uploader)
            }
            notifyDelegates()
        }
    }

    /// Registers a cached worker, retaining live handles and replacing failed ones, without
    /// reviving an upload acknowledged after the cache snapshot was read.
    internal func restorePersistedUpload(_ uploader: ChunkedFileUploader) -> DirectUpload? {
        if let existing = storage.upload(forID: uploader.uploadInfo.id) {
            return existing
        }
        uploader.addDelegate(
            withToken: UUID().uuidString,
            makeUploaderDelegate()
        )
        let upload = DirectUpload(wrapping: uploader, uploadManager: self)
        return storage.restore(upload, worker: uploader)
    }
    
    /// Adds a ``DirectUploadManagerDelegate``. You can add as many of these as you like.
    public func addDelegate<Delegate: DirectUploadManagerDelegate>(_ delegate: Delegate) {
        storage.addDelegate(delegate)
    }

    /// Removes an ``DirectUploadManagerDelegate``
    public func removeDelegate<Delegate: DirectUploadManagerDelegate>(_ delegate: Delegate) {
        storage.removeDelegate(delegate)
    }

    internal func acknowledgeUpload(id: String) {
        acknowledgeUpload(id: id, matching: nil)
    }

    private func acknowledgeUpload(id: String, matching worker: ChunkedFileUploader?) {
        let upload = storage.removeUpload(forID: id, matching: worker) { [self] in
            await uploadActor.remove(uploadID: id)
            notifyDelegates()
        }

        // Reenters this class via the uploader's delegate callbacks, so it has
        // to happen after unlocking.
        upload?.fileWorker?.cancel()
    }
    
    internal func findChunkedFileUploader(
        inputFileURL: URL,
        uploadURL: URL
    ) -> ChunkedFileUploader? {
        storage.uploader(inputFileURL: inputFileURL, uploadURL: uploadURL)
    }

    internal func registerUpload(_ upload: DirectUpload) {

        guard let fileWorker = upload.fileWorker else {
            // Only started uploads, aka uploads with a file
            // worker can be registered.
            // TODO: Should this throw?
            SDKLogger.logger?.debug("registerUpload() called for an unstarted upload")
            return
        }

        fileWorker.addDelegate(
            withToken: UUID().uuidString,
            makeUploaderDelegate()
        )
        storage.insert(
            upload,
            worker: fileWorker,
            persistence: persistenceUpdate(for: fileWorker, state: fileWorker.currentState)
        )
        self.notifyDelegates()
    }

    private func persistenceUpdate(
        for uploader: ChunkedFileUploader,
        state: ChunkedFileUploader.InternalUploadState
    ) -> () async -> Void {
        let persistedState = uploader.persistenceState(for: state)
        return { [self] in
            await uploadActor.updateUpload(
                uploader.uploadInfo,
                fileInputURL: uploader.inputFileURL,
                withUpdate: persistedState
            )
            notifyDelegates()
        }
    }
    
    private func notifyDelegates() {
        Task { @MainActor in
            // No await between snapshot and delivery: the main actor is serial,
            // so the last notification to arrive also holds the newest
            // snapshot. Snapshotting before the hop lets notifications deliver
            // out of order and the upload list appear to move backwards.
            let snapshot = self.storage.notificationSnapshot()

            // Unlocked by now, so a delegate may call back in.
            for delegate in snapshot.delegates {
                delegate.didUpdate(managedDirectUploads: snapshot.uploads)
            }
        }
    }
    
    /// The shared instance of this object that should be used.
    public static let shared = DirectUploadManager()
    
    private struct FileUploaderDelegate : ChunkedFileUploaderDelegate {
        let manager: DirectUploadManager
        
        func chunkedFileUploader(
            _ uploader: ChunkedFileUploader,
            stateUpdated state: ChunkedFileUploader.InternalUploadState
        ) {
            switch state {
            case .canceled:
                manager.acknowledgeUpload(id: uploader.uploadInfo.id, matching: uploader)
            default:
                manager.storage.recordState(
                    of: uploader,
                    state: state,
                    persistence: manager.persistenceUpdate(for: uploader, state: state)
                )
            }
        }
    }
}

/// A delegate that handles changes to the list of active uploads.
public protocol DirectUploadManagerDelegate: AnyObject {
    /// Called when the global list of uploads changes. This happens whenever a new upload starts, or an existing one completes or fails.
    func didUpdate(managedDirectUploads: [DirectUpload])
}


/// Isolates/synchronizes multithreaded access to the upload cache.
internal actor UploadCacheActor {
    private let persistence: UploadPersistence
    
    func updateUpload(
        _ uploadInfo: UploadInfo,
        fileInputURL: URL,
        withUpdate update: ChunkedFileUploader.InternalUploadState
    ) async {
        persistence.update(
            uploadState: update,
            for: uploadInfo,
            fileInputURL: fileInputURL
        )
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
                where: { $0.inputFileURL == ofFileAt || $0.uploadInfo.sourceFileURL == ofFileAt }
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
        try? persistence.remove(entryAtID: uploadID)
    }
    
    init(persistence: UploadPersistence = try! UploadPersistence()) {
        // This try-assert is safe if the process home dir is writeable (which it is generally)
        self.persistence = persistence
    }
}
