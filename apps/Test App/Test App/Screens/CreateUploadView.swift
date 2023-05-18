//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI
import PhotosUI

struct CreateUploadView: View {
    
    @StateObject var uploadCreationVM: UploadCreationModel = UploadCreationModel()
    
    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxNavBar(leadingNavButton: .close, title: "Create a New Upload")
                ScreenContentView(exportState: uploadCreationVM.exportState)
            }
        }
        .environmentObject(uploadCreationVM)
    }
}

fileprivate struct ScreenContentView: View {
    var body: some View {
        ZStack {
            WindowBackground
            switch exportState {
            case .not_started: EmptyView()
            case .preparing: ProcessingView()
            case .failure(let error): ErrorView(error: error)
            case .ready(let upload): ThumbnailView(preparedMedia: upload)
            }
            
        }
    }
    
    let exportState: ExportState
}

fileprivate struct ErrorView: View {
    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 4.0)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                    .foregroundColor(Gray30)
                    .background(Gray90)
                VStack {
                    Label(
                        "",
                        systemImage: "square.and.arrow.up.trianglebadge.exclamationmark"
                    )
                    .foregroundColor(.red)
                    Spacer()
                        .frame(maxHeight: 12)
                    Text("Couln't prepare the video for upload. Please try another video")
                        .foregroundColor(White)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .padding(.leading)
                        .padding(.trailing)
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
            .frame(height: Test_AppApp.THUMBNAIL_HEIGHT)
            
            Spacer()
        }
    }
    
    let error: Error?
    
    init(error: Error? = nil) {
        self.error = error
    }
}


fileprivate struct ThumbnailView: View {
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            ZStack {
                if let image = preparedMedia?.thumbnail {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 4.0)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                            .foregroundColor(Gray30)
                            .background(
                                Image(
                                    image,
                                    scale: 1.0,
                                    label: Text("")
                                )
                                .resizable( )
                                .scaledToFit()
                                .aspectRatio(contentMode: .fill)
                                .frame(maxWidth: proxy.size.width, maxHeight: proxy.size.height, alignment: .center)
                                .clipShape(
                                    RoundedRectangle(cornerRadius: 4.0)
                                )
                            )
                    }
                } else {
                    RoundedRectangle(cornerRadius: 4.0)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                        .foregroundColor(Gray30)
                        .background(Gray30.clipShape(RoundedRectangle(cornerRadius: 4.0)))
                    // Processing can succeed without a thumbnail theoretically
                    Image(systemName: "video.badge.checkmark")
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
            .frame(height: Test_AppApp.THUMBNAIL_HEIGHT)
            Spacer()
            StretchyDefaultButton("Upload") {
                if let preparedMedia = preparedMedia {
                    let upload = uploadCreationVM.startUpload(preparedMedia: preparedMedia, forceRestart: true)
                    dismiss()
                }
            }
            .padding()
        }
    }
    
    let preparedMedia: PreparedUpload?
    @EnvironmentObject var uploadCreationVM: UploadCreationModel
    
    init(preparedMedia: PreparedUpload?) {
        self.preparedMedia = preparedMedia
    }
}

fileprivate struct ProcessingView: View {
    var body: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 4.0)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                    .foregroundColor(Gray30)
                    .background(Gray30.clipShape(RoundedRectangle(cornerRadius: 4.0)))
                ProgressView()
                    .foregroundColor(Gray30)
            }
            .padding(
                EdgeInsets(
                    top: 64,
                    leading: 20,
                    bottom: 0,
                    trailing: 20
                )
            )
            .frame(height: Test_AppApp.THUMBNAIL_HEIGHT)
            Spacer()
        }
    }
}

fileprivate struct EmptyView: View {
    var body: some View {
        VStack {
            UploadCTA()
                .padding(
                    EdgeInsets(
                        top: 64,
                        leading: 20,
                        bottom: 0,
                        trailing: 20
                    )
                )
            Spacer()
        }
    }
}

fileprivate struct UploadCTA: View {
    @EnvironmentObject var uploadCreationVM: UploadCreationModel
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
            BigUploadCTALabel()
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
                        uploadCreationVM.tryToPrepare(from: firstVideo)
                    }
                }
            )}
        )
        .onAppear {
            inPickFlow = true
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

struct ContentContainer_Previews: PreviewProvider {
    static var previews: some View {
        let exportState = ExportState.ready(
            PreparedUpload(thumbnail: nil, localVideoFile: URL(string: "file:///")!, remoteURL: URL(string: "file:///")!)
        )
        ScreenContentView(exportState: exportState)
            .environmentObject(UploadCreationModel())
    }
}

struct EntireScreen_Previews: PreviewProvider {
    static var previews: some View {
        CreateUploadView()
            .environmentObject(UploadCreationModel())
    }
}

struct Thumbnail_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ThumbnailView(preparedMedia: PreparedUpload(thumbnail: nil, localVideoFile: URL(string: "file:///")!, remoteURL: URL(string: "file:///")!))
        }
        .environmentObject(UploadCreationModel())
    }
}

struct EmptyView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            EmptyView()
        }
        .environmentObject(UploadCreationModel())
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ErrorView()
        }
        .environmentObject(UploadCreationModel())
    }
}

struct ProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ProcessingView()
        }
        .environmentObject(UploadCreationModel())
    }
}
