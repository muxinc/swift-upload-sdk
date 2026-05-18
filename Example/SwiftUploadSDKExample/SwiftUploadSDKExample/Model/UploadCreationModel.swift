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

final class UploadCreationModel: ObservableObject, @unchecked Sendable {

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
    private var thumbnailGenerator: AVAssetImageGenerator? = nil

    private let logger = SwiftUploadSDKExample.logger
    private let myServerBackend = FakeBackend(urlSession: URLSession(configuration: URLSessionConfiguration.default))

    @Published var photosAuthStatus: PhotosAuthState
    @Published var exportState: ExportState = .not_started
    @Published var currentUpload: DirectUpload?
    @Published var uploadProgress: DirectUpload.TransportStatus?
    @Published var uploadResult: DirectUploadResult?
    @Published var uploadErrorMessage: String?
    @Published var isStartingUpload = false
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
        self.exportState = .not_started
    }

    func resetSelection() {
        prepareTask?.cancel()
        if let assetRequestId {
            PHImageManager.default().cancelImageRequest(assetRequestId)
        }
        assetRequestId = nil
        thumbnailGenerator?.cancelAllCGImageGeneration()
        currentUpload?.cancel()
        currentUpload = nil
        uploadProgress = nil
        uploadResult = nil
        uploadErrorMessage = nil
        isStartingUpload = false
        pickedItem = []
        exportState = .not_started
    }

    func startPreparedUpload() {
        guard case .ready(let preparedMedia) = exportState else {
            uploadErrorMessage = "No prepared video"
            return
        }

        startUpload(preparedMedia: preparedMedia)
    }

    // TODO: Add pause/resume/restore controls when building the interrupted-upload test harness.
    private func startUpload(preparedMedia: PreparedUpload) {
        // DirectUpload is the SDK entry point: pass the Mux direct upload URL and the local media asset.
        let upload = DirectUpload(
            uploadURL: preparedMedia.remoteURL,
            inputAsset: AVAsset(url: preparedMedia.localVideoFile),
            options: .default
        )
        attachHandlers(to: upload)
        currentUpload = upload
        uploadProgress = nil
        uploadResult = nil
        uploadErrorMessage = nil
        isStartingUpload = true

        // forceRestart=false lets the SDK use its normal resumable upload path.
        upload.start(forceRestart: false)
    }

    private func attachHandlers(to upload: DirectUpload) {
        // The SDK reports upload progress and final success/failure through these callbacks.
        upload.progressHandler = { [weak self, weak upload] progress in
            DispatchQueue.main.async { [weak self, weak upload] in
                guard let self, let upload, upload === self.currentUpload else {
                    return
                }
                self.isStartingUpload = false
                self.uploadProgress = progress
            }
        }
        upload.resultHandler = { [weak self, weak upload] result in
            DispatchQueue.main.async { [weak self, weak upload] in
                guard let self, let upload, upload === self.currentUpload else {
                    return
                }
                self.isStartingUpload = false
                self.uploadResult = result
                if case .failure(let error) = result {
                    self.uploadErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Prepares the selected video as a local file before handing it to the upload SDK.
    func tryToPrepare(from pickerItem: PhotosPickerItem) {
        prepareTask?.cancel()
        currentUpload = nil
        uploadProgress = nil
        uploadResult = nil
        uploadErrorMessage = nil
        isStartingUpload = false
        exportState = .preparing

        let tempFile = FileManager.default.temporaryDirectory
            .appending(component: "upload-\(Date().timeIntervalSince1970)")
            .appendingPathExtension("mp4")

        guard photosAuthStatus.canFetchPhotoKitAssets else {
            prepareTransferredFileForUpload(from: pickerItem, outFile: tempFile)
            return
        }

        guard let itemIdentifier = pickerItem.itemIdentifier else {
            self.logger.error("No item identifier for chosen video")
            Task.detached {
                await MainActor.run {
                    self.exportState = .failure(
                        PickerError.assetExportSessionFailed
                    )
                }
            }
            return
        }

        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
        let fetchAssetResult = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: options)
        guard let fetchedAsset = fetchAssetResult.firstObject else {
            self.logger.error("No Asset fetched")
            self.exportState = .failure(PickerError.missingAssetIdentifier)
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
                        self.exportState = .failure(UploadCreationModel.PickerError.assetExportSessionFailed)
                        return
                    }
                    self.exportToOutFile(session: exportSession, outFile: tempFile)
                }
            }
        )
    }

    private func prepareTransferredFileForUpload(from pickerItem: PhotosPickerItem, outFile: URL) {
        prepareTask?.cancel()
        prepareTask = Task.detached { [self] in
            do {
                guard let uploadInput = try await pickerItem.loadTransferable(type: UploadInput.self) else {
                    await MainActor.run {
                        self.exportState = .failure(PickerError.assetExportSessionFailed)
                    }
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
                    self.exportState = .ready(
                        PreparedUpload(thumbnail: thumbnailImage, localVideoFile: outFile, remoteURL: putURL)
                    )
                }
            } catch {
                self.logger.error("Failed to prepare transferred video: \(error.localizedDescription)")
                await MainActor.run {
                    self.exportState = .failure(PickerError.assetExportSessionFailed)
                }
            }
        }
    }

    private func exportToOutFile(session: AVAssetExportSession, outFile: URL) {
        session.outputURL = outFile
        session.outputFileType = AVFileType.mp4
        prepareTask = Task.detached { [self] in
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
                    // This is already on the main thread
                    self.logger.debug("Yay, Media exported & ready for upload!")
                    self.assetRequestId = nil
                    // Deliver result
                    self.exportState = .ready(
                        PreparedUpload(thumbnail: thumbnailImage, localVideoFile: outFile, remoteURL: putURL)
                    )
                }
            } catch {
                self.logger.error("Failed to create Upload: \(error.localizedDescription)")
                Task.detached {
                    await MainActor.run {
                        self.exportState = .failure(PickerError.createUploadFailed)
                    }
                }
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
            switch result {
            case .cancelled: do {
                self.logger.debug("Thumbnail request canceled")
            }
            case .failed: do {
                self.logger.error("Failed to extract thumnail: \(error?.localizedDescription ?? "unknown")")
            }
            case .succeeded: do {
                Task.detached {
                    await MainActor.run {
                        thenDo(image)
                    }
                }
            }
            @unknown default:
                self.logger.error("Unknown thumbnail generation result")
            }
        }

    }

}

struct PreparedUpload {
    let thumbnail: CGImage?
    let localVideoFile: URL
    let remoteURL: URL
}

enum ExportState {
    case not_started
    case preparing
    case failure(UploadCreationModel.PickerError)
    case ready(PreparedUpload)
}

enum PhotosAuthState {
    case notDetermined
    case cant_auth(PHAuthorizationStatus)
    case can_auth(PHAuthorizationStatus)
    case authorized(PHAuthorizationStatus)
}

extension PhotosAuthState {
    var canFetchPhotoKitAssets: Bool {
        switch self {
        case .authorized:
            return true
        case .notDetermined, .can_auth, .cant_auth:
            return false
        }
    }
}

extension PHAuthorizationStatus {
    func asAppAuthState() -> PhotosAuthState {
        switch self {
        case .authorized: return PhotosAuthState.authorized(self)
        case .limited: return PhotosAuthState.can_auth(self)
        case .notDetermined: return PhotosAuthState.notDetermined
        case .restricted: return  PhotosAuthState.cant_auth(self)
        case .denied: return PhotosAuthState.cant_auth(self)
        @unknown default: return PhotosAuthState.can_auth(self) // It's for future compat, why not be optimistic?
        }
    }
}
