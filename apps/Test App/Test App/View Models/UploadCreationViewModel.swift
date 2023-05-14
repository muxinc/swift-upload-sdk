//
//  UploadCreationViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 5/14/23.
//

import Foundation
import PhotosUI

class UploadCreationViewModel : ObservableObject {
    
    struct PickerError: Error {
        
        static var unexpectedFormat: PickerError {
            PickerError(localizedDescription: "Unexpected video file format")
        }
        
        static var missingAssetIdentifier: PickerError {
            PickerError(localizedDescription: "Missing asset identifier")
        }
        
        var localizedDescription: String
        
    }
    
    func requestPhotosAccess() {
        switch photosAuthStatus {
        case .cant_auth(_): logger.critical("This application can't ask for permission to access photos. Check your Info.plist for NSPhotoLibraryAddUsageDescription, and make sure to use a physical device with this app")
        case .authorized(_): logger.warning("requestPhotosAccess called but we already had access. ignoring")
        case .can_auth(_): doRequestPhotosPermission()
        }
    }
    
    /// Prepares a Photos Asset for upload by exporting it to a local temp file
    func tryToPrepare(from pickerResult: PHPickerResult) {
        if let assetRequestId = assetRequestId {
            PHImageManager.default().cancelImageRequest(assetRequestId)
        }
        
        // TODO: This is a very common workflow. Should the SDK be able to do this workflow with Photos?
        exportState = .preparing
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = URL(string: "upload-\(Date().timeIntervalSince1970).mp4", relativeTo: tempDir)!
        
        guard let assetIdentitfier = pickerResult.assetIdentifier else {
            NSLog("!! No Asset ID for chosen asset")
            exportState = .failure(nil)
            return
        }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = .typeUserLibrary
        let phAssetResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentitfier], options: options)
        guard let phAsset = phAssetResult.firstObject else {
            NSLog("!! No Asset fetched")
            DispatchQueue.main.sync {
                self.exportState = .failure(PickerError.missingAssetIdentifier)
            }
            return
        }
        
        let exportOptions = PHVideoRequestOptions()
        //exportOptions.deliveryMode = .highQualityFormat
        assetRequestId = PHImageManager.default().requestExportSession(forVideo: phAsset, options: exportOptions, exportPreset: AVAssetExportPresetHighestQuality, resultHandler: {(exportSession, info) -> Void in
            DispatchQueue.main.async {
                guard let exportSession = exportSession else {
                    NSLog("!! No Export session")
                    self.exportState = .failure(nil)
                    return
                }
                self.exportToOutFile(session: exportSession, outFile: tempFile)
            }
        })
    }
    
    private func exportToOutFile(session: AVAssetExportSession, outFile: URL) {
        session.outputURL = outFile
        session.outputFileType = AVFileType.mp4
        //session.shouldOptimizeForNetworkUse = false
        session.exportAsynchronously {
            DispatchQueue.main.async {
                NSLog("Yay, Media exported & ready for upload!")
                // TODO: Set the result and stuff
            }
        }
    }
    
    private func doRequestPhotosPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task.detached {
                await MainActor.run {
                    self.photosAuthStatus = status.asAppAuthState()
                }
            }
        }
    }
    
    private var assetRequestId: PHImageRequestID? = nil
    
    private var prepareTask: Task<Any, Never>? = nil
    private let logger = Test_AppApp.logger
    
    @Published
    var preparedAsset: (PHAsset, URL)?
    @Published
    var photosAuthStatus: PhotosAuthState
    @Published
    var exportState: ExportState
    
    init() {
        let innerAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.photosAuthStatus = innerAuthStatus.asAppAuthState()
        self.exportState = .not_started
    }
}

enum ExportState {
    case not_started, preparing, failure(UploadCreationViewModel.PickerError?), ready(PHAsset, URL)
}

enum PhotosAuthState {
    case cant_auth(PHAuthorizationStatus), can_auth(PHAuthorizationStatus), authorized(PHAuthorizationStatus)
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
