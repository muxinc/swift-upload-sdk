//
//  MainPage.swift
//  Test App
//
//  Created by Emily Dixon on 2/15/23.
//

import SwiftUI
import Foundation
import MuxUploadSDK
import PhotosUI

struct UploadScreen: View {
    @EnvironmentObject var uploadScreenViewModel: UploadScreenViewModel
    @State var inPickFlow = false // True when picking photos or resolving the related permission prompt
    @State var lastUploadStatus: MuxUpload.Status? = nil
    
    private var pickerConfig: PHPickerConfiguration = {
        let mediaFilter = PHPickerFilter.any(of: [.videos])
        var photoPickerConfig = PHPickerConfiguration(photoLibrary: .shared())
        photoPickerConfig.filter = mediaFilter
        photoPickerConfig.preferredAssetRepresentationMode = .current
        photoPickerConfig.selectionLimit = 1
        if #available(iOS 15.0, *) {
            photoPickerConfig.selection = .default
        }
        return photoPickerConfig
    }()
    
    var body: some View {
        VStack {
            Button("Upload a Video") { [self] in
                switch uploadScreenViewModel.photosAuthStatus {
                case .can_auth(_): do {
                    inPickFlow = true
                    uploadScreenViewModel.requestPhotosAccess()
                }
                case .authorized(_): do {
                    inPickFlow = true
                }
                case .cant_auth(_): do {
                    Test_AppApp.logger.error("!! This app  cannot ask for or gain Photos access permissions for some reason. You can probably fix this by uninstalling, and making sure 'NSPhotoLibraryAddUsageDescription' is in the app plist")
                }
                }
            }
            .disabled(shouldDisableButton())
            .buttonStyle(CtaButtonStyle())
            .padding(Edge.Set.top, 18.0)
            
            UploadProgressView(
                appUploadState: uploadScreenViewModel.uploadScreenState,
                viewModel: uploadScreenViewModel
            )
        }
        .padding()
        .sheet(
            isPresented: Binding<Bool>(
                get: { self.shouldShowPhotoPicker() },
                set: { value, _ in inPickFlow = value && isAuthorizedForPhotos() }
            ),
            content: { ImagePicker(
                pickerConfiguration: self.pickerConfig,
                delegate: { (images: [PHPickerResult]) in
                    // Only 0 or 1 images can be selected
                    if let firstVideo = images.first {
                        inPickFlow = false
                        uploadScreenViewModel.startUpload(video: firstVideo)
                    }
                }
            )}
        )
    }
    
    private func shouldShowPhotoPicker() -> Bool {
        if isAuthorizedForPhotos() {
            return inPickFlow
        } else {
            return false
        }
    }
    
    private func shouldDisableButton() -> Bool {
        if isAuthorizedForPhotos() {
            return false
        } else {
            return inPickFlow
        }
    }
    
    private func isAuthorizedForPhotos() -> Bool {
        switch uploadScreenViewModel.photosAuthStatus {
        case .authorized(_): return true
        default: return false
        }
    }
}

struct MainPage_Previews: PreviewProvider {
    static var previews: some View {
        UploadScreen()
            .environmentObject(UploadScreenViewModel())
    }
}
