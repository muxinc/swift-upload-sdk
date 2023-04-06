//
//  UploadScreenViewModel.swift
//  Test App
//
//  Created by Emily Dixon on 2/15/23.
//

import Foundation
import MuxUploadSDK
import SwiftUI
import PhotosUI

class UploadScreenViewModel: ObservableObject {

    struct PickerError: Error {

        static var unexpectedFormat: PickerError {
            PickerError(
                localizedDescription: "Unexpected video file format"
            )
        }

        static var missingAssetIdentifier: PickerError {
            PickerError(
                localizedDescription: "Missing asset identifier"
            )
        }

        var localizedDescription: String

    }
    
    let PUT_URL = "https://storage.googleapis.com/video-storage-gcp-us-east4-vop1-uploads/4OAV5fGb8RMf2ElvbeLz8I?Expires=1680807117&GoogleAccessId=uploads-gcp-us-east1-vop1%40mux-video-production.iam.gserviceaccount.com&Signature=dOFesy7mXnbKnytmdDsFKCVVZ6lW12JvPsTPOxSn0egin4WD6hVOQpTAmc3XycR%2F7OkoYKnTV6wauec9mrjLkOF4fdGuHUC76YZTMhezUFxNZYkEkf7rniRRUuiuJp%2B5IZvCdkYX0VfNMUDHG1pzi8XvEVN1evLI6CoA%2F6OPUJOtMC%2BX%2FTLlHUvFVzwPk06CzzjYer7ZE3O72UMtXFEAs4QAsf0L3eTfWJav4si%2F6F1Y3BgO4ypG7zKmStxsvQNa%2F71DlIwxo%2BO0n2iJFfh48te9kvI%2B7cqsgb7aaQcLIotJ040Jps5mRDlC5Q35yRIWhxRNmCfSLRnLUB1104SNwQ%3D%3D&upload_id=ADPycdu7bDavvtbJw3M9ukiH30zs06Ql-Twu7EHWfSKb48kvXU6Xd2Zn4EgBteTLwE3A0KrQEGg2H7p9rRKUX9D_Kt7OU_DHcGl4"
    
    @Published
    var uploadScreenState: AppUploadState = .not_started
    @Published
    var photosAuthStatus: PhotosAuthState
    
    private var upload: MuxUpload? = nil
    private let logger = Test_AppApp.logger
    
    func requestPhotosAccess() {
        switch photosAuthStatus {
        case .cant_auth(_): logger.critical("This application can't ask for permission to access photos. Check your Info.plist for NSPhotoLibraryAddUsageDescription, and make sure to use a physical device with this app")
        case .authorized(_): logger.warning("requestPhotosAccess called but we already had access. ignoring")
        case .can_auth(_): doRequestPhotosPermission()
        }
    }
    
    func startUpload(video: PHPickerResult) {
        copyTempFile(video: video)
    }
    
    func pauseUpload() {
        if let upload = upload {
            upload.pause()
        }
    }
    
    func resumeUpload() {
        if let upload = upload {
            upload.start()
        }
    }
    
    func isPaused() -> Bool {
        switch uploadScreenState {
        case .preparing: return false
        case .uploading(let status): return status.isPaused
        default: return true
        }
    }
    
    private func doRequestPhotosPermission() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.sync {
                self.photosAuthStatus = status.asAppAuthState()
            }
        }
    }
    
    /// When working with the device's media library, we must copy the file we wish to upload into a temp dir and "export" it into our own app directory, which may result in transcoding
    private func copyTempFile(video: PHPickerResult) {
        // TODO: This is a very common workflow. Should the SDK be able to do this workflow with Photos?
        uploadScreenState = .preparing
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = URL(string: "upload-\(Date().timeIntervalSince1970).mp4", relativeTo: tempDir)!
        
        guard let assetIdentitfier = video.assetIdentifier else {
            NSLog("!! No Asset ID for chosen asset")
            uploadScreenState = .failure(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.includeAssetSourceTypes = .typeUserLibrary
            let phAssetResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentitfier], options: options)
            guard let phAsset = phAssetResult.firstObject else {
                NSLog("!! No Asset fetched")
                DispatchQueue.main.sync {
                    self.uploadScreenState = .failure(PickerError.missingAssetIdentifier)
                }
                return
            }
            
            let exportOptions = PHVideoRequestOptions()
            //exportOptions.deliveryMode = .highQualityFormat
            // TODO: Probably store exportRequestId
            let exportRequestId = PHImageManager.default().requestExportSession(forVideo: phAsset, options: exportOptions, exportPreset: AVAssetExportPresetHighestQuality, resultHandler: {(exportSession, info) -> Void in
                DispatchQueue.main.async {
                    guard let exportSession = exportSession else {
                        NSLog("!! No Export session")
                        self.uploadScreenState = .failure(nil)
                        return
                    }
                    self.exportToOutFile(session: exportSession, outFile: tempFile)
                }
            })
        }
    }
    
    private func exportToOutFile(session: AVAssetExportSession, outFile: URL) {
        session.outputURL = outFile
        session.outputFileType = AVFileType.mp4
        //session.shouldOptimizeForNetworkUse = false
        session.exportAsynchronously {
            DispatchQueue.main.async {
                NSLog("Yay, Media exported & ready for upload!")
                self.beginUploadToMux(videoFile: outFile)
            }
        }
    }
    
    private func beginUploadToMux(videoFile: URL) {
        let upload = MuxUpload(
            uploadURL: URL(string: PUT_URL)!,
            videoFileURL: videoFile,
            videoMIMEType: "video/*"
        )

        upload.progressHandler = { state in
            self.uploadScreenState = .uploading(state)
        }
        
        upload.resultHandler = { result in
            // TODO: Delete the temp file
            switch result {
            case .success(let success):
                self.uploadScreenState = .done(success)
                self.upload = nil
                NSLog("Upload Success!")
            case .failure(let error):
                self.uploadScreenState = .failure(error)
                NSLog("!! Upload error: \(error.localizedDescription)")
            }
        }
        
        self.upload = upload
        upload.start()
    }
    
    init() {
        let innerAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.photosAuthStatus = innerAuthStatus.asAppAuthState()
    }
}

enum AppUploadState {
    case not_started, preparing, uploading(MuxUpload.Status), failure(Error?), done(MuxUpload.Success)
}

enum PhotosAuthState {
    case cant_auth(PHAuthorizationStatus), can_auth(PHAuthorizationStatus), authorized(PHAuthorizationStatus)
}

fileprivate extension PHAuthorizationStatus {
    func asAppAuthState() -> PhotosAuthState {
        switch self {
        case .authorized, .limited: return PhotosAuthState.authorized(self)
        case .restricted: return  PhotosAuthState.cant_auth(self)
        case .denied, .notDetermined: return PhotosAuthState.can_auth(self)
        @unknown default: return PhotosAuthState.can_auth(self) // It's for future compat, why not be optimistic?
        }
    }
}
