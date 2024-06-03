//
//  CreateUploadScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/9/23.
//

import SwiftUI
import PhotosUI

struct CreateUploadView: View {
    
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    var body: some View {
        ZStack { // Outer window
            Gray100.ignoresSafeArea(.container)
            VStack(spacing: 0) {
                MuxNavBar(
                    leadingNavButton: .close,
                    title: "Create a New Upload"
                )
                ZStack {
                    WindowBackground
                    switch uploadCreationModel.exportState {
                    case .not_started: EmptyView()
                    case .preparing: ProcessingView()
                    case .failure(let error): ErrorView(error: error)
                    case .ready(let upload): ThumbnailView(preparedMedia: upload)
                    }

                }
            }
        }
        .environmentObject(uploadCreationModel)
    }
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

                    Text(message)
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
            .frame(height: SwiftUploadSDKExample.thumbnailHeight)
            
            Spacer()
        }
    }
    
    let error: Error?

    let message: String
    
    init(error: Error? = nil) {
        self.error = error
        self.message = "Couldn't prepare the video for upload. Please try another video."
    }

    init(error: UploadCreationModel.PickerError) {
        self.error = error

        if error == UploadCreationModel.PickerError.createUploadFailed {
            self.message = "Couldn't create direct upload. Check your access token and network connectivity."
        } else {
            self.message = "Couldn't prepare the video for upload. Please try another video."
        }
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
            .frame(height: SwiftUploadSDKExample.thumbnailHeight)
            Spacer()
            StretchyDefaultButton("Upload") {
                if let preparedMedia = preparedMedia {
                    uploadCreationVM.startUpload(preparedMedia: preparedMedia, forceRestart: true)
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
            .frame(height: SwiftUploadSDKExample.thumbnailHeight)
            Spacer()
        }
    }
}

fileprivate struct EmptyView: View {
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    @State var pickedItem: PhotosPickerItem?

    var body: some View {
        VStack {
            PhotosPicker(
                selection: $pickedItem,
                matching: .videos,
                preferredItemEncoding: .current,
                label: {
                    UploadCallToActionLabel()
                }
            )
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
