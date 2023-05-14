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
    
    init() {
        let innerAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.photosAuthStatus = innerAuthStatus.asAppAuthState()
    }
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
