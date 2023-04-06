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
    
    let PUT_URL = "https://storage.googleapis.com/video-storage-gcp-us-east4-vop1-uploads/KmgByhv1MfRPismF8kPK3G?Expires=1678317874&GoogleAccessId=uploads-gcp-us-east1-vop1%40mux-video-production.iam.gserviceaccount.com&Signature=L%2BrmPZ2LW%2FOHrvXops0V%2Bp8AYuGRV3CkLywUl5lNdhWTQe3Iz85WXnDCLmAWnTNmiGVx3RWtAf5zRJ0Ahgcaz7hkq7kPpvUgx2NRzLukSeRix9CHowcshgqI8eQEtSx7HKxD8E2%2Boh0ur7tldNDCjBoTofg7yEzSu%2F2pqPp3qySf3nnjdbI86miKmLEK7d1YO431L3Ai5N6axWA9pR78cgrq7X48%2FqhDHmITtqRwx%2Baossr2Jar9FRY2PLFIHFawnyKbYGfmGHwDIR%2FCaqOFTUlnSKpbFJ5BZPGCu2HQVZbhuBSrWthg34hczlFT0K5410MMksyLXn8j0LC%2B757cQw%3D%3D&upload_id=ADPycdv6m_6zr0XH6-0w2EdY2wZzspZ1ofLu-2l9e64ni24k-FX66g31mkyHcawdRv5ITVksYpwJUU6VKblDkq143jKR"
    
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
                self.beginMuxUpload(videoFile: outFile)
            }
        }
    }
    
    private func beginMuxUpload(videoFile: URL) {
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
