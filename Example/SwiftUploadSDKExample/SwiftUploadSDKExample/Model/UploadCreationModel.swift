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
        // PhotosPicker can provide a readable temporary file without requiring full PhotoKit access.
        FileRepresentation(
            importedContentType: .movie
        ) { receivedTransferedFile in
            UploadInput(file: receivedTransferedFile.file)
        }
    }
}

@MainActor
final class UploadCreationModel: ObservableObject {

    struct PickerError: Error, Equatable {

        static var missingAssetIdentifier: PickerError {
            PickerError(localizedDescription: "Missing asset identifier")
        }

        static var createUploadFailed: PickerError {
            PickerError(localizedDescription: "Upload could not be created")
        }

        static var assetExportSessionFailed: PickerError {
            PickerError(localizedDescription: "Upload could not be exported")
        }

        var localizedDescription: String
    }

    private var assetRequestId: PHImageRequestID? = nil
    private var prepareTask: Task<Void, Never>? = nil
    private var resumeTask: Task<Void, Never>? = nil
    private var thumbnailGenerator: AVAssetImageGenerator? = nil

    private let logger = SwiftUploadSDKExample.logger
    private let myServerBackend = FakeBackend(urlSession: URLSession(configuration: URLSessionConfiguration.default))

    @Published var photosAuthStatus: PhotosAuthState
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
        let innerAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.photosAuthStatus = innerAuthStatus.asAppAuthState()
        self.workflowState = .idle
    }

    func resetSelection() {
        prepareTask?.cancel()
        resumeTask?.cancel()
        cancelPhotoKitRequests()
        cancelActiveUpload()
        pickedItem = []
        workflowState = .idle
    }

    func startPreparedUpload() {
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
            options: .default
        )
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
                guard let self, let upload, self.isCurrentUpload(upload) else {
                    return
                }
                self.workflowState = .completed(result, preparedMedia: preparedMedia)
            }
        }
    }

    /// Prepares the selected video as a local file before handing it to the upload SDK.
    func tryToPrepare(from pickerItem: PhotosPickerItem) {
        prepareTask?.cancel()
        resumeTask?.cancel()
        cancelPhotoKitRequests()
        cancelActiveUpload()
        workflowState = .preparing

        let tempFile = FileManager.default.temporaryDirectory
            .appending(component: "upload-\(Date().timeIntervalSince1970)")
            .appendingPathExtension("mp4")

        guard photosAuthStatus.canFetchPhotoKitAssets else {
            prepareTransferredFileForUpload(from: pickerItem, outFile: tempFile)
            return
        }

        guard let itemIdentifier = pickerItem.itemIdentifier else {
            self.logger.error("No item identifier for chosen video")
            self.workflowState = .preparationFailed(PickerError.assetExportSessionFailed)
            return
        }

        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        let fetchAssetResult = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: options)
        guard let fetchedAsset = fetchAssetResult.firstObject else {
            self.logger.error("No Asset fetched")
            self.workflowState = .preparationFailed(PickerError.missingAssetIdentifier)
            return
        }

        let exportOptions = PHVideoRequestOptions()
        exportOptions.isNetworkAccessAllowed = true
        exportOptions.deliveryMode = .highQualityFormat
        self.assetRequestId = PHImageManager.default().requestExportSession(
            forVideo: fetchedAsset,
            options: exportOptions,
            exportPreset: AVAssetExportPresetPassthrough,
            resultHandler: {(exportSession, info) -> Void in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    guard let exportSession = exportSession else {
                        self.logger.error("!! No Export session")
                        self.workflowState = .preparationFailed(UploadCreationModel.PickerError.assetExportSessionFailed)
                        return
                    }
                    self.exportToOutFile(session: exportSession, outFile: tempFile)
                }
            }
        )
    }

    private func prepareTransferredFileForUpload(from pickerItem: PhotosPickerItem, outFile: URL) {
        prepareTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                guard let uploadInput = try await pickerItem.loadTransferable(type: UploadInput.self) else {
                    self.workflowState = .preparationFailed(PickerError.assetExportSessionFailed)
                    return
                }

                if FileManager.default.fileExists(atPath: outFile.path) {
                    try FileManager.default.removeItem(at: outFile)
                }
                try FileManager.default.copyItem(at: uploadInput.file, to: outFile)

                let asset = AVAsset(url: outFile)
                // The SDK uploads to a direct upload URL created by the app's backend.
                let putURL = try await self.myServerBackend.createDirectUpload()
                if Task.isCancelled {
                    return
                }

                extractThumbnailAsync(asset) { thumbnailImage in
                    self.logger.debug("Yay, Media ready for upload!")
                    self.workflowState = .ready(
                        PreparedUpload(thumbnail: thumbnailImage, localVideoFile: outFile, remoteURL: putURL)
                    )
                }
            } catch {
                self.logger.error("Failed to prepare transferred video: \(error.localizedDescription)")
                self.workflowState = .preparationFailed(PickerError.assetExportSessionFailed)
            }
        }
    }

    private func exportToOutFile(session: AVAssetExportSession, outFile: URL) {
        session.outputURL = outFile
        session.outputFileType = AVFileType.mp4
        prepareTask = Task { [weak self] in
            guard let self else {
                return
            }

            await session.export()
            if Task.isCancelled {
                return
            }

            do {
                // The SDK uploads to a direct upload URL created by the app's backend.
                let putURL = try await self.myServerBackend.createDirectUpload()
                if Task.isCancelled {
                    return
                }

                extractThumbnailAsync(session.asset) { thumbnailImage in
                    self.logger.debug("Yay, Media exported & ready for upload!")
                    self.assetRequestId = nil
                    self.workflowState = .ready(
                        PreparedUpload(thumbnail: thumbnailImage, localVideoFile: outFile, remoteURL: putURL)
                    )
                }
            } catch {
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
                }
                case .failed: do {
                    self.logger.error("Failed to extract thumnail: \(error?.localizedDescription ?? "unknown")")
                }
                case .succeeded: do {
                    thenDo(image)
                }
                @unknown default:
                    self.logger.error("Unknown thumbnail generation result")
                }
            }
        }

    }

    private func cancelPhotoKitRequests() {
        if let assetRequestId {
            PHImageManager.default().cancelImageRequest(assetRequestId)
        }
        assetRequestId = nil
        thumbnailGenerator?.cancelAllCGImageGeneration()
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

enum PhotosAuthState {
    case notDetermined
    case cantAuth(PHAuthorizationStatus)
    case canAuth(PHAuthorizationStatus)
    case authorized(PHAuthorizationStatus)
}

extension PhotosAuthState {
    var canFetchPhotoKitAssets: Bool {
        switch self {
        case .authorized:
            return true
        case .notDetermined, .canAuth, .cantAuth:
            return false
        }
    }
}

extension PHAuthorizationStatus {
    func asAppAuthState() -> PhotosAuthState {
        switch self {
        case .authorized: return PhotosAuthState.authorized(self)
        case .limited: return PhotosAuthState.canAuth(self)
        case .notDetermined: return PhotosAuthState.notDetermined
        case .restricted: return PhotosAuthState.cantAuth(self)
        case .denied: return PhotosAuthState.cantAuth(self)
        @unknown default: return PhotosAuthState.canAuth(self) // It's for future compat, why not be optimistic?
        }
    }
}
