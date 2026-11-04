//
//  DirectUploadManager.swift
//  Manages large file uploads in a global context for access by many UI elements
//
//  Created by Emily Dixon on 3/8/23.
//

import AVFoundation
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
        var isActive: Bool
        var selectionDate: TimeInterval

        enum WorkerState {
            case available, failed, finished
        }

        static func precedes(_ lhs: UploadStorage, _ rhs: UploadStorage) -> Bool {
            if lhs.isActive != rhs.isActive { return !lhs.isActive }
            if lhs.selectionDate != rhs.selectionDate { return lhs.selectionDate < rhs.selectionDate }
            return lhs.worker.uploadInfo.id < rhs.worker.uploadInfo.id
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
        private var _unsafePreparations: [String: DirectUpload] = [:]
        private var _unsafeDelegatesByToken: [ObjectIdentifier: any DirectUploadManagerDelegate] = [:]
        // Retained for this manager's lifetime so even an old cache snapshot
        // cannot restore an acknowledged upload. Explicit registration permits a restart.
        private var _unsafeAcknowledgedIDs: Set<String> = []
        private var _unsafePersistenceTask: Task<Void, Never>?

        func upload(ofFile url: URL) -> DirectUpload? {
            withLock {
                _unsafeUploadsByID.values.filter {
                    $0.workerState == .available && ($0.worker.inputFileURL == url || $0.worker.uploadInfo.sourceFileURL == url)
                }.max(by: UploadStorage.precedes)?.upload
                    ?? _unsafePreparations.values.first { $0.sourceFileURL == url }
            }
        }

        func allUploads() -> [DirectUpload] {
            withLock {
                Array(_unsafeUploadsByID.values.map(\.upload)) + Array(_unsafePreparations.values)
            }
        }

        func upload(forID id: String) -> DirectUpload? {
            withLock {
                if let preparing = _unsafePreparations[id] { return preparing }
                guard let stored = _unsafeUploadsByID[id], stored.workerState != .failed else { return nil }
                return stored.upload
            }
        }

        func uploader(inputFileURL: URL, uploadURL: URL) -> ChunkedFileUploader? {
            withLock {
                _unsafeUploadsByID.values.filter {
                    $0.workerState == .available && ($0.worker.inputFileURL == inputFileURL || $0.worker.uploadInfo.sourceFileURL == inputFileURL)
                        && $0.worker.uploadInfo.uploadURL == uploadURL
                }.max(by: UploadStorage.precedes)?.worker
            }
        }

        func markStarted(_ worker: ChunkedFileUploader) {
            withLock {
                let id = worker.uploadInfo.id
                guard var stored = _unsafeUploadsByID[id], stored.worker === worker,
                      stored.workerState == .available, !stored.isActive else { return }
                stored.isActive = true
                stored.selectionDate = Date().timeIntervalSince1970
                _unsafeUploadsByID[id] = stored
            }
        }

        func prepare(_ upload: DirectUpload, persistence: (() async -> Void)? = nil) -> DirectUpload? {
            withLock {
                if persistence == nil, _unsafeAcknowledgedIDs.contains(upload.id) { return nil }
                if let existing = _unsafePreparations[upload.id], persistence == nil { return existing }
                _unsafeAcknowledgedIDs.remove(upload.id)
                if _unsafeUploadsByID[upload.id]?.workerState == .failed {
                    _unsafeUploadsByID.removeValue(forKey: upload.id)
                }
                _unsafePreparations[upload.id] = upload
                if let persistence { enqueuePersistence(persistence) }
                return upload
            }
        }

        func insert(_ upload: DirectUpload, worker: ChunkedFileUploader, persistence: @escaping () async -> Void) {
            withLock {
                _unsafeAcknowledgedIDs.remove(upload.id)
                _unsafePreparations.removeValue(forKey: upload.id)
                _unsafeUploadsByID[upload.id] = UploadStorage(
                    upload: upload, worker: worker, isActive: true,
                    selectionDate: Date().timeIntervalSince1970
                )
                enqueuePersistence(persistence)
            }
        }

        func restore(_ upload: DirectUpload, worker: ChunkedFileUploader, savedAt: TimeInterval) -> DirectUpload? {
            withLock {
                guard !_unsafeAcknowledgedIDs.contains(upload.id) else { return nil }
                if let existing = _unsafeUploadsByID[upload.id], existing.workerState != .failed {
                    return existing.upload
                }
                _unsafeUploadsByID[upload.id] = UploadStorage(
                    upload: upload, worker: worker, isActive: false, selectionDate: savedAt
                )
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
                case .paused: stored.isActive = false
                case .starting, .uploading:
                    if !stored.isActive { stored.selectionDate = Date().timeIntervalSince1970 }
                    stored.isActive = true
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
                let preparing = _unsafePreparations.removeValue(forKey: id)
                return _unsafeUploadsByID.removeValue(forKey: id)?.upload ?? preparing
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
                    uploads: Array(_unsafeUploadsByID.values.map(\.upload)) + Array(_unsafePreparations.values)
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
    
    /// Finds a managed upload and returns its ``DirectUpload`` handle, which can be observed
    /// to track and control its state.
    /// When sessions share a file, prefers active transfers, then the most recently started or saved session.
    /// Returns nil if there is no active or paused upload for the given file.
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
    /// Retains a live managed handle when available, preferring active transfers. Otherwise restores the newest saved session.
    /// Returns nil if there is no matching live handle or persisted upload.
    public func resumeDirectUpload(ofFile url: URL) async -> DirectUpload? {
        await storage.pendingPersistenceTask()?.value
        if let existing = storage.upload(ofFile: url) {
            notifyDelegates()
            return existing
        }
        if let entry = await uploadActor.preparation(ofFile: url) {
            return restorePreparation(entry)
        }
        guard let uploader = await uploadActor.getUpload(ofFileAt: url),
              let upload = restorePersistedUpload(uploader) else { return nil }
        notifyDelegates()
        return upload
    }
    
    /// Attempts to resume an upload that was previously paused, failed, or interrupted by process death.
    /// Calls completion on the main thread when a matching managed or persisted upload is found.
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
        resumeAllDirectUploads { result in
            if case .failure = result { SDKLogger.logger?.error("Could not restore managed uploads") }
        }
    }

    /// An authoritative restoration result, independent of unrelated delegate updates.
    /// Completion is delivered on the main thread. Restored uploads are not started automatically.
    public func resumeAllDirectUploads(completion: @escaping (Result<[DirectUpload], Error>) -> Void) {
        Task { [self] in
            await waitForPersistence()
            let result: Result<[DirectUpload], Error>
            do {
                for entry in try await uploadActor.entries() {
                    if entry.stateCode == .preparing { _ = restorePreparation(entry) }
                    else { _ = restorePersistedUpload(ChunkedFileUploader(persistenceEntry: entry)) }
                }
                result = .success(storage.allUploads())
            } catch { result = .failure(error) }
            notifyDelegates()
            await MainActor.run { completion(result) }
        }
    }

    private func restorePreparation(_ entry: PersistenceEntry) -> DirectUpload? {
        if let live = storage.upload(forID: entry.uploadInfo.id) { return live }
        let upload = DirectUpload(input: UploadInput(asset: AVURLAsset(url: entry.inputFileURL), info: entry.uploadInfo),
                                  uploadManager: self)
        return storage.prepare(upload)
    }

    internal func registerPreparation(_ upload: DirectUpload) async throws {
        let source = upload.sourceFileURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = storage.prepare(upload) { [self] in
                do {
                    try await uploadActor.savePreparation(upload.uploadInfo, source: source)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        notifyDelegates()
    }

    internal func waitForPersistence() async { await storage.pendingPersistenceTask()?.value }

    internal func retryWorker(id: String) async -> ChunkedFileUploader? {
        await waitForPersistence()
        return await uploadActor.getUpload(uploadID: id)
    }

    internal func canRestartPreparation(id: String) async -> Bool {
        await waitForPersistence()
        return await uploadActor.canRestartPreparation(id: id)
    }

    internal func recordTerminalState(_ worker: ChunkedFileUploader, state: ChunkedFileUploader.InternalUploadState) {
        storage.recordState(of: worker, state: state, persistence: persistenceUpdate(for: worker, state: state))
    }

    private func configurePayloadValidation(_ worker: ChunkedFileUploader) {
        worker.beforeUpload = { [weak worker, self] in
            await waitForPersistence()
            guard let worker else { throw CancellationError() }
            worker.allowsExistingServerBytes = try await uploadActor.prepareTransport(
                id: worker.uploadInfo.id, file: worker.inputFileURL)
        }
    }

    /// Registers a cached worker, retaining live handles and replacing failed ones, without
    /// reviving an upload acknowledged after the cache snapshot was read.
    internal func restorePersistedUpload(_ uploader: ChunkedFileUploader) -> DirectUpload? {
        if let existing = storage.upload(forID: uploader.uploadInfo.id) {
            return existing
        }
        configurePayloadValidation(uploader)
        uploader.addDelegate(
            withToken: UUID().uuidString,
            makeUploaderDelegate()
        )
        let upload = DirectUpload(wrapping: uploader, uploadManager: self)
        let savedAt: TimeInterval
        if case .paused(let update) = uploader.currentState { savedAt = update.updateTime }
        else { savedAt = 0 }
        return storage.restore(upload, worker: uploader, savedAt: savedAt)
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

    internal func markUploadStarted(_ uploader: ChunkedFileUploader) {
        storage.markStarted(uploader)
    }

    internal func registerUpload(_ upload: DirectUpload) {

        guard let fileWorker = upload.fileWorker else {
            // Only started uploads, aka uploads with a file
            // worker can be registered.
            // TODO: Should this throw?
            SDKLogger.logger?.debug("registerUpload() called for an unstarted upload")
            return
        }

        configurePayloadValidation(fileWorker)
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
    
    internal func notifyDelegates() {
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
    
    func entries() throws -> [PersistenceEntry] { try persistence.readAll() }

    func savePreparation(_ inputInfo: UploadInfo, source: URL) throws {
        var info = inputInfo
        info.sourceFileURL = source
        let existing = try persistence.readAll()
        guard !existing.contains(where: { $0.uploadInfo.uploadURL == info.uploadURL && $0.uploadInfo.id != info.id }) else {
            throw UploadRecoveryError.newUploadRequired
        }
        try persistence.write(entry: PersistenceEntry(savedAt: Date().timeIntervalSince1970, stateCode: .preparing,
            lastSuccessfulByte: 0, uploadInfo: info, inputFileURL: source), for: info.id)
    }

    func preparation(ofFile url: URL) -> PersistenceEntry? {
        try? persistence.readAll().filter { $0.stateCode == .preparing && $0.inputFileURL == url }
            .max { $0.savedAt < $1.savedAt }
    }

    func prepareTransport(id: String, file: URL) async throws -> Bool {
        guard let before = try persistence.readEntry(uploadID: id), before.inputFileURL == file, before.stateCode != .preparing else {
            try Task.checkCancellation()
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        let hashing = Task.detached { try uploadPayloadDigest(at: file) }
        let digest = try await withTaskCancellationHandler(operation: { try await hashing.value },
                                                          onCancel: { hashing.cancel() })
        try Task.checkCancellation()
        guard let entry = try persistence.readEntry(uploadID: id), entry.inputFileURL == file,
              entry.stateCode != .preparing else { throw CancellationError() }
        if let expected = entry.payloadDigest, expected != digest { throw UploadRecoveryError.payloadChanged }
        try persistence.write(entry: entry.with(payloadDigest: digest, inputFileURL: file,
            uploadURL: entry.uploadInfo.uploadURL), for: id)
        return entry.payloadDigest != nil || entry.lastSuccessfulByte > 0
    }

    func canRestartPreparation(id: String) -> Bool {
        // A preparing record is safe to regenerate: the transport barrier
        // prohibits all network requests until the payload record is durable.
        (try? persistence.readEntry(uploadID: id))?.stateCode == .preparing
    }

    func getUpload(uploadID: String) async -> ChunkedFileUploader? {
        guard let entry = try? persistence.readEntry(uploadID: uploadID), entry.stateCode != .preparing else { return nil }
        return ChunkedFileUploader(persistenceEntry: entry)
    }

    func getUpload(ofFileAt url: URL) async -> ChunkedFileUploader? {
        guard let entry = try? persistence.readAll().filter({
            $0.stateCode != .preparing && ($0.inputFileURL == url || $0.uploadInfo.sourceFileURL == url)
        }).max(by: {
            if $0.savedAt != $1.savedAt { return $0.savedAt < $1.savedAt }
            return $0.uploadInfo.id < $1.uploadInfo.id
        }) else { return nil }
        return ChunkedFileUploader(persistenceEntry: entry)
    }

    func getAllUploads() async -> [ChunkedFileUploader] {
        (try? persistence.readAll().filter { $0.stateCode != .preparing }.map(ChunkedFileUploader.init(persistenceEntry:))) ?? []
    }

    func remove(uploadID: String) async {
        try? persistence.remove(entryAtID: uploadID)
    }
    
    init(persistence: UploadPersistence = try! UploadPersistence()) {
        // This try-assert is safe if the process home dir is writeable (which it is generally)
        self.persistence = persistence
    }
}
