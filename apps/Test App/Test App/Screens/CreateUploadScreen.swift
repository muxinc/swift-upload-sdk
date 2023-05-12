//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI
import PhotosUI

struct CreateUploadScreen: View {
    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxyNavBar()
                ScreenContent()
            }
        }
    }
}

struct ScreenContent: View {
    @EnvironmentObject var uploadScreenViewModel: UploadScreenViewModel
    
    var body: some View {
        ZStack {
            WindowBackground
            // TODO: If we have a thumbnail loaded, that's what we want to show
            EmptyView()
        }
    }
}

struct EmptyView: View {
    @EnvironmentObject var uploadScreenViewModel: UploadScreenViewModel
    @State var inPickFlow = false // True when picking photos or resolving the related permission prompt
    
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
            BigUploadCTA() { [self] in
                switch uploadScreenViewModel.photosAuthStatus {
                case .can_auth(_): do {
                    inPickFlow = true
                    uploadScreenViewModel.requestPhotosAccess()
                }
                case .authorized(_): do {
                    inPickFlow = true
                }
                case .cant_auth(_): do {
                    NSLog("!! This app  cannot ask for or gain Photos access permissions for some reason. We don't expect to see this on a real device unless 'NSPhotoLibraryAddUsageDescription' is gone from the app plist")
                }
                }
            }
            .padding(
                EdgeInsets(
                    top: 64,
                    leading: 20,
                    bottom: 0,
                    trailing: 20
                )
            )
            .disabled(shouldDisableButton())
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
            Spacer()
        }
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

struct CreateUploadScreen_Previews: PreviewProvider {
    static var previews: some View {
        CreateUploadScreen()
            .environmentObject(UploadScreenViewModel())
    }
}

struct EmptyView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            EmptyView()
        }.environmentObject(UploadScreenViewModel())
    }
}
