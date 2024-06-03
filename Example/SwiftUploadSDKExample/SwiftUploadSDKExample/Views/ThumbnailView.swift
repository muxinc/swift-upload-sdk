//
//  ThumbnailView.swift
//  SwiftUploadSDKExample
//

import SwiftUI

struct ThumbnailView: View {
    let preparedMedia: PreparedUpload?
    @EnvironmentObject var uploadCreationModel: UploadCreationModel
    @Environment(\.dismiss) private var dismiss

    init(preparedMedia: PreparedUpload?) {
        self.preparedMedia = preparedMedia
    }

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
                    uploadCreationModel.startUpload(
                        preparedMedia: preparedMedia,
                        forceRestart: true
                    )
                    dismiss()
                }
            }
            .padding()
        }
    }
}

struct ThumbnailView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ThumbnailView(preparedMedia: PreparedUpload(thumbnail: nil, localVideoFile: URL(string: "file:///")!, remoteURL: URL(string: "file:///")!))
        }
        .environmentObject(UploadCreationModel())
    }
}
