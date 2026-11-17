//
//  UploadCreationViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/14/23.
//

import Foundation
import PhotosUI
import MuxUploadSDK
import SwiftUI

struct UploadInput: Transferable {
    let file: URL
    static var transferRepresentation: some TransferRepresentation {
        // PhotosPicker hands over a copy of the selected video without requiring
        // any photo library permission.
        FileRepresentation(
            importedContentType: .movie
        ) { receivedTransferedFile in
            // The received file is owned by the system and is only guaranteed to
            // exist until this closure returns, so copy it somewhere we own now.
            let sourceFile = receivedTransferedFile.file
            let fileExtension = sourceFile.pathExtension.isEmpty ? "mov" : sourceFile.pathExtension
            let destinationFile = FileManager.default.temporaryDirectory
                .appending(component: "upload-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try FileManager.default.copyItem(at: sourceFile, to: destinationFile)
            return UploadInput(file: destinationFile)
        }
    }
}

@MainActor
final class UploadCreationModel: ObservableObject, DirectUploadManagerDelegate {

    /// Keep the SDK's on-device resolution tier aligned with the Direct Upload
    /// created by the trusted environment. This sample uses the 1080p tier so
    /// it does not opt into higher-resolution Mux processing by default.
    /// To demonstrate 4K, change both values to `.preset3840x2160` and `"2160p"`.
    /// To produce SDR on the device, change `hdrHandling` to `.toneMapToSDR`.
    private static let uploadConfiguration = ExampleUploadConfiguration(
        inputStandardization: .init(
            maximumResolution: .preset1920x1080,
            hdrHandling: .preserve
        ),
        muxMaximumResolutionTier: "1080p"
    )

    struct PickerError: Error, Equatable {

        static var createUploadFailed: PickerError {
            PickerError(localizedDescription: "Upload could not be created")
        }

        static var assetExportSessionFailed: PickerError {
            PickerError(localizedDescription: "Upload could not be exported")
        }

        var localizedDescription: String
    }

    private var prepareTask: Task<Void, Never>? = nil
    private var preparationID: UUID?
    private var resumeTask: Task<Void, Never>? = nil
    private var thumbnailGenerator: AVAssetImageGenerator? = nil

    private let logger = SwiftUploadSDKExample.logger
    private let fakeBackend = FakeBackend(
        urlSession: URLSession(configuration: URLSessionConfiguration.default)
    )

    @Published private(set) var hasFinishedRestoringUploads = false
    @Published var workflowState: WorkflowState = .idle
    @Published var pickedItem: [PhotosPickerItem] = [] {
        didSet {
            guard let pickedItem = pickedItem.first else {
                return
            }
            tryToPrepare(from: pickedItem)
        }
    }

    init() {
        DirectUploadManager.shared.addDelegate(self)
        DirectUploadManager.shared.resumeAllDirectUploads()
    }

    nonisolated func didUpdate(managedDirectUploads uploads: [DirectUpload]) {
        DirectUploadManager.shared.removeDelegate(self)
        Task { @MainActor in
            defer { self.hasFinishedRestoringUploads = true }
            for upload in uploads where !upload.inProgress && !upload.complete {
                guard let source = (upload.inputAsset as? AVURLAsset)?.url else { continue }
                let prepared = PreparedUpload(thumbnail: nil, localVideoFile: source, remoteURL: upload.uploadURL)
                self.attachHandlers(to: upload, preparedMedia: prepared)
                if case .idle = self.workflowState {
                    self.workflowState = .uploading(upload, progress: upload.uploadStatus, preparedMedia: prepared)
                }
                upload.start()
            }
        }
    }

    func resetSelection() {
        cancelPreparation()
        resumeTask?.cancel()
        cancelActiveUpload()
        pickedItem = []
        workflowState = .idle
    }

    func startPreparedUpload() {
        guard hasFinishedRestoringUploads else { return }
        guard case .ready(let preparedMedia) = workflowState else {
            assertionFailure("startPreparedUpload called without prepared media")
            return
        }

        startUpload(preparedMedia: preparedMedia)
    }

    func resumeManagedUpload(for preparedMedia: PreparedUpload) {
        resumeTask?.cancel()
        workflowState = .restoring(preparedMedia)

        resumeTask = Task { [weak self] in
            guard let self else {
                return
            }

            // This is the SDK's managed-upload restore path. If it returns nil, the SDK
            // could not find persisted state for the selected local file.
            guard let upload = await DirectUploadManager.shared.resumeDirectUpload(
                ofFile: preparedMedia.localVideoFile
            ) else {
                guard !Task.isCancelled else {
                    return
                }
                self.workflowState = .restoreFailed(
                    "No persisted upload was found for this local video file.",
                    preparedMedia: preparedMedia
                )
                return
            }
            guard !Task.isCancelled else {
                return
            }

            self.attachHandlers(to: upload, preparedMedia: preparedMedia)
            self.workflowState = .uploading(
                upload,
                progress: upload.uploadStatus,
                preparedMedia: preparedMedia
            )
            upload.start(forceRestart: false)
        }
    }

    private func startUpload(preparedMedia: PreparedUpload) {
        // DirectUpload is the SDK entry point: pass the Mux direct upload URL and the local media asset.
        let upload = DirectUpload(
            uploadURL: preparedMedia.remoteURL,
            inputAsset: AVAsset(url: preparedMedia.localVideoFile),
            options: DirectUploadOptions(
                inputStandardization: Self.uploadConfiguration.inputStandardization
            )
        )

        // Input standardization is best effort. Returning false uploads the
        // original input when the SDK cannot inspect, convert, or validate it.
        // Return true here if your application should cancel instead.
        upload.nonStandardInputHandler = {
            SwiftUploadSDKExample.logger.warning(
                "Input standardization did not complete; uploading the original input"
            )
            return false
        }

        attachHandlers(to: upload, preparedMedia: preparedMedia)
        workflowState = .uploading(upload, progress: nil, preparedMedia: preparedMedia)

        // forceRestart=false lets the SDK use its normal resumable upload path.
        upload.start(forceRestart: false)
    }

    private func attachHandlers(to upload: DirectUpload, preparedMedia: PreparedUpload) {
        // The SDK reports upload progress and final success/failure through these callbacks.
        upload.progressHandler = { [weak self, weak upload] progress in
            Task { @MainActor in
                guard let self, let upload, self.isCurrentUpload(upload) else {
                    return
                }
                self.workflowState = .uploading(upload, progress: progress, preparedMedia: preparedMedia)
            }
        }
        upload.resultHandler = { [weak self, weak upload] result in
            Task { @MainActor in
                switch result {
                case .success: self?.removeCopiedInput(preparedMedia.localVideoFile)
                case .failure(let error) where error.kind == .cancelled:
                    self?.removeCopiedInput(preparedMedia.localVideoFile)
                default: break // Failed uploads still need their original for retry.
                }
                guard let self, let upload, self.isCurrentUpload(upload) else {
                    return
                }
                self.workflowState = .completed(result, preparedMedia: preparedMedia)
            }
        }
    }

    /// Prepares the selected video as a local file before handing it to the upload SDK.
    func tryToPrepare(from pickerItem: PhotosPickerItem) {
        guard hasFinishedRestoringUploads else { return }
        cancelPreparation()
        resumeTask?.cancel()
        cancelActiveUpload()
        workflowState = .preparing

        var directory = inputDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        catch { workflowState = .preparationFailed(PickerError.assetExportSessionFailed); return }
        let preparationID = UUID()
        self.preparationID = preparationID

        prepareTask = Task { [weak self] in
            guard let self else {
                return
            }
            var copiedFile: URL?
            var handedToThumbnail = false
            defer { if !handedToThumbnail, let copiedFile { self.removeCopiedInput(copiedFile) } }

            // PhotosPicker gives us a copy of the selected video without any photo library permission.
            let localVideoFile: URL
            do {
                let uploadInput = try await pickerItem.loadTransferable(type: UploadInput.self)
                guard !Task.isCancelled, self.preparationID == preparationID else {
                    if let uploadInput { try? FileManager.default.removeItem(at: uploadInput.file) }
                    return
                }
                guard let uploadInput else {
                    self.workflowState = .preparationFailed(PickerError.assetExportSessionFailed)
                    return
                }

                // Move the picker's temporary copy somewhere that survives relaunch,
                // so an interrupted upload can be resumed from the same file.
                // Keep the source's extension so the container type isn't misrepresented.
                localVideoFile = directory
                    .appendingPathComponent("upload-\(preparationID.uuidString)")
                    .appendingPathExtension(uploadInput.file.pathExtension)
                copiedFile = localVideoFile
                do {
                    try FileManager.default.moveItem(at: uploadInput.file, to: localVideoFile)
                } catch {
                    try? FileManager.default.removeItem(at: uploadInput.file)
                    throw error
                }
                self.logger.debug("tryToPrepare: transferable loaded. File: \(localVideoFile.absoluteString)")
            } catch {
                guard !Task.isCancelled, self.preparationID == preparationID else { return }
                self.logger.error("Failed to load selected video: \(error.localizedDescription)")
                self.workflowState = .preparationFailed(PickerError.assetExportSessionFailed)
                return
            }

            do {
                // The SDK uploads to a Direct Upload URL created in a trusted environment.
                let putURL = try await self.fakeBackend.createDirectUpload(
                    maxResolutionTier: Self.uploadConfiguration.muxMaximumResolutionTier
                )
                guard !Task.isCancelled, self.preparationID == preparationID else { return }

                self.logger.debug("extracting thumbnail")
                extractThumbnailAsync(AVAsset(url: localVideoFile)) { thumbnailImage in
                    guard self.preparationID == preparationID else { self.removeCopiedInput(localVideoFile); return }
                    self.logger.debug("Yay, Media ready for upload!")
                    self.workflowState = .ready(
                        PreparedUpload(thumbnail: thumbnailImage, localVideoFile: localVideoFile, remoteURL: putURL)
                    )
                }
                handedToThumbnail = true
            } catch {
                guard !Task.isCancelled, self.preparationID == preparationID else { return }
                self.logger.error("Failed to create Upload: \(error.localizedDescription)")
                self.workflowState = .preparationFailed(PickerError.createUploadFailed)
            }
        }
    }

    private func extractThumbnailAsync(_ asset: AVAsset, thenDo: @escaping (CGImage?) -> Void) {
        if let thumbnailGenerator = thumbnailGenerator {
            thumbnailGenerator.cancelAllCGImageGeneration()
        }

        thumbnailGenerator = AVAssetImageGenerator(asset: asset)
        thumbnailGenerator?.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime.zero)]) {
            requestedTime,
            image,
            actualTime,
            result,
            error
            in
            Task { @MainActor in
                switch result {
                case .cancelled: do {
                    self.logger.debug("Thumbnail request canceled")
                    thenDo(nil)
                }
                case .failed: do {
                    self.logger.error("Failed to extract thumnail: \(error?.localizedDescription ?? "unknown")")
                    thenDo(nil)
                }
                case .succeeded: do {
                    thenDo(image)
                }
                @unknown default:
                    self.logger.error("Unknown thumbnail generation result")
                    thenDo(nil)
                }
            }
        }

    }

    private func cancelThumbnailGeneration() {
        thumbnailGenerator?.cancelAllCGImageGeneration()
    }

    private var inputDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExampleUploadInputs", isDirectory: true)
    }

    private func removeCopiedInput(_ url: URL) {
        guard url.isFileURL, url.lastPathComponent.hasPrefix("upload-"),
              url.standardizedFileURL.deletingLastPathComponent().path
                .hasSuffix("/Library/Application Support/ExampleUploadInputs") else { return }
        // Resolve our copy in the current container, including after a reinstall.
        try? FileManager.default.removeItem(at: inputDirectory.appendingPathComponent(url.lastPathComponent))
    }

    private func cancelPreparation() {
        preparationID = nil
        prepareTask?.cancel()
        cancelThumbnailGeneration()
        switch workflowState {
        case .ready(let prepared), .completed(.failure(_), let prepared), .restoreFailed(_, let prepared):
            // Picking another video abandons this session, including its saved checkpoint.
            for upload in DirectUploadManager.shared.allManagedDirectUploads()
                where upload.uploadURL == prepared.remoteURL {
                upload.cancel()
            }
            removeCopiedInput(prepared.localVideoFile)
        default: break
        }
        // An in-flight copy/export removes its own output after it stops writing.
    }

    private func cancelActiveUpload() {
        guard case .uploading(let upload, _, _) = workflowState else {
            return
        }
        upload.cancel()
    }

    private func isCurrentUpload(_ upload: DirectUpload) -> Bool {
        guard case .uploading(let currentUpload, _, _) = workflowState else {
            return false
        }
        return upload === currentUpload
    }

}

private struct ExampleUploadConfiguration {
    let inputStandardization: DirectUploadOptions.InputStandardization
    let muxMaximumResolutionTier: String
}

struct PreparedUpload {
    let thumbnail: CGImage?
    let localVideoFile: URL
    let remoteURL: URL
}

enum WorkflowState {
    case idle
    case preparing
    case preparationFailed(UploadCreationModel.PickerError)
    case ready(PreparedUpload)
    case uploading(DirectUpload, progress: DirectUpload.TransportStatus?, preparedMedia: PreparedUpload)
    case restoring(PreparedUpload)
    case restoreFailed(String, preparedMedia: PreparedUpload)
    case completed(DirectUploadResult, preparedMedia: PreparedUpload)
}
