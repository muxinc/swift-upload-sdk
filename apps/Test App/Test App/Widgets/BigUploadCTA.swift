//
//  BigUploadCta.swift
//  Test App
//
//  Created by Emily Dixon on 5/11/23.
//

import SwiftUI
import PhotosUI

struct BigUploadCTA: View {
    @EnvironmentObject var uploadCreationVM: UploadCreationViewModel
    @State var inPickFlow = false // True when picking photos or resolving the related permission prompt, or when first launching the screen
    
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
        Button { [self] in
            switch uploadCreationVM.photosAuthStatus {
            case .can_auth(_): do {
                inPickFlow = true
                uploadCreationVM.requestPhotosAccess()
            }
            case .authorized(_): do {
                inPickFlow = true
            }
            case .cant_auth(_): do {
                NSLog("!! This app  cannot ask for or gain Photos access permissions for some reason. We don't expect to see this on a real device unless 'NSPhotoLibraryAddUsageDescription' is gone from the app plist")
            }
            }
        } label : {
            ZStack {
                RoundedRectangle(cornerRadius: 4.0)
                    .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4]))
                    .foregroundColor(Gray30)
                    .opacity(0.5)
                VStack(spacing: 0) {
                    Image("Mux-y Add")
                        .padding()
                    Text("Tap to upload video")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(White)
                }
            }
            .frame(height: 228)
        }
        .contentShape(Rectangle())
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
                        // TODO: ViewModel creates remote upload and exports the video file
                        uploadCreationVM.tryToPrepare(from: firstVideo)
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
        switch uploadCreationVM.photosAuthStatus {
        case .authorized(_): return true
        default: return false
        }
    }
    
    let actionOnMediaAvailable: (PHAsset, URL) -> Void
    
    init(_ actionOnMediaAvailable: @escaping (PHAsset, URL) -> Void = {_,_ in }) {
        self.actionOnMediaAvailable = actionOnMediaAvailable
    }
}

struct BigUploadCTA_Preview: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            BigUploadCTA()
                .padding(EdgeInsets(top: 64, leading: 20, bottom: 0, trailing: 20))
        }
        .environmentObject(UploadCreationViewModel())
    }
}
