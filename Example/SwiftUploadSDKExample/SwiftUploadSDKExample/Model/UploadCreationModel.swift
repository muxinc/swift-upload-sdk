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
        FileRepresentation(
            contentType: .mpeg4Movie
        ) { transferable in
            SentTransferredFile(transferable.file)
        } importing: { receivedTransferedFile in
            UploadInput(file: receivedTransferedFile.file)
        }
    }
}

class UploadCreationModel : ObservableObject {
    
    struct PickerError: Error, Equatable {
        
        static var unexpectedFormat: PickerError {
            PickerError(localizedDescription: "Unexpected video file format")
        }
        
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
    @Published var pickedItem: [PhotosPickerItem] = [] {
        didSet {
            tryToPrepare(from: pickedItem.first!)
        }
    }

    init() {
        let innerAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.photosAuthStatus = innerAuthStatus.asAppAuthState()
        self.exportState = .not_started
    }
    
    @discardableResult func startUpload(preparedMedia: PreparedUpload, forceRestart: Bool) -> DirectUpload {
        let upload = DirectUpload(
            uploadURL: preparedMedia.remoteURL,
            inputAsset: AVAsset(url: preparedMedia.localVideoFile),
            options: .default
        )
        upload.progressHandler = { progress in
            self.logger.info("Uploading \(progress.progress?.completedUnitCount ?? 0)/\(progress.progress?.totalUnitCount ?? 0)")
        }
        upload.resultHandler = { result in }
        upload.start(forceRestart: true)
        return upload
    }
    
    /// Prepares a Photos Asset for upload by exporting it to a local temp file
    func tryToPrepare(from pickerItem: PhotosPickerItem) {
        exportState = .preparing
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = URL(
            string: "upload-\(Date().timeIntervalSince1970).mp4",
            relativeTo: tempDir
        )!

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

        doRequestPhotosPermission { authorizationStatus in
            Task.detached {
                await MainActor.run {
                    self.photosAuthStatus = authorizationStatus.asAppAuthState()

                    let options = PHFetchOptions()
                    options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
                    let fetchAssetResult = PHAsset.fetchAssets(withLocalIdentifiers: [itemIdentifier], options: options)
                    guard let fetchedAsset = fetchAssetResult.firstObject else {
                        self.logger.error("No Asset fetched")
                        Task.detached {
                            await MainActor.run {
                                self.exportState = .failure(
                                    PickerError.missingAssetIdentifier
                                )
                            }
                        }
                        return
                    }

                    let exportOptions = PHVideoRequestOptions()
                    exportOptions.isNetworkAccessAllowed = true
                    exportOptions.deliveryMode = .highQualityFormat
                    self.assetRequestId = PHImageManager.default().requestExportSession(
                        forVideo: fetchedAsset,
                        options: exportOptions,
                        exportPreset: AVAssetExportPresetHighestQuality,
                        resultHandler: {(exportSession, info) -> Void in
                        DispatchQueue.main.async {
                            guard let exportSession = exportSession else {
                                self.logger.error("!! No Export session")
                                self.exportState = .failure(UploadCreationModel.PickerError.assetExportSessionFailed)
                                return
                            }
                            self.exportToOutFile(session: exportSession, outFile: tempFile)
                        }
                    })
                }
            }
        }
    }
    
    private func exportToOutFile(session: AVAssetExportSession, outFile: URL) {
        session.outputURL = outFile
        session.outputFileType = AVFileType.mp4
        //session.shouldOptimizeForNetworkUse = false
        prepareTask = Task.detached { [self] in
            await session.export()
            if Task.isCancelled {
                return
            }
            
            do {
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
                fatalError()
            }
        }
        
    }
    
    private func doRequestPhotosPermission(
        handler: @escaping (PHAuthorizationStatus) -> Void
    ) {
        PHPhotoLibrary.requestAuthorization(
            for: .readWrite,
            handler: handler
        )
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
    case cant_auth(PHAuthorizationStatus)
    case can_auth(PHAuthorizationStatus)
    case authorized(PHAuthorizationStatus)
}

extension PHAuthorizationStatus {
    func asAppAuthState() -> PhotosAuthState {
        switch self {
        case .authorized, .limited: return PhotosAuthState.authorized(self)
        case .restricted: return  PhotosAuthState.cant_auth(self)
        case .denied, .notDetermined: return PhotosAuthState.can_auth(self)
        @unknown default: return PhotosAuthState.can_auth(self) // It's for future compat, why not be optimistic?
        }
    }
}
