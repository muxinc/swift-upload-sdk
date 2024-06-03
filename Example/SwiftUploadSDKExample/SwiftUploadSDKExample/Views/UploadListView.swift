//
//  UploadListScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/15/23.
//

import SwiftUI
import MuxUploadSDK
import AVFoundation



extension DirectUpload {
    var objectIdentifier: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}

struct UploadListContainerView: View {
    
    @EnvironmentObject var uploadListModel: UploadListModel

    var body: some View {
        if uploadListModel.lastKnownUploads.isEmpty {
            UploadListPlaceholderView()
        } else {
            ScrollView {
                LazyVStack {
                    ForEach(
                        uploadListModel.lastKnownUploads,
                        id: \.objectIdentifier
                    ) { upload in
                        ListItem(upload: upload)
                    }
                }
            }
        }
    }
}

fileprivate struct ListItem: View {
    
    @StateObject var thumbnailModel: ThumbnailModel
    let upload: DirectUpload
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = thumbnailModel.thumbnail {
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
                    .background(Gray90.clipShape(RoundedRectangle(cornerRadius: 4.0)))
            }
            if upload.inProgress {
                HStack() {
                    VStack (alignment: .leading, spacing: 0) {
                        Text("Uploading...")
                            .font(.system(
                                size: 14.0,
                                weight: .light)
                            )
                            .foregroundColor(White)
                            .frame(alignment: .leading)
                            .padding(
                                EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0)
                            )
                        ProgressView(value: thumbnailModel.uploadProgress?.progress?.fractionCompleted ?? 0)
                            .progressViewStyle(.linear)
                            .tint(Green50)
                            .padding(
                                EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0)
                            )
                        Text(statusLine(status: thumbnailModel.uploadProgress))
                            .font(.system(
                                size: 14.0,
                                weight: .light)
                            )
                            .foregroundColor(White)
                            .frame(alignment: .leading)
                    }
                    .padding()
                }
                .background(TransparentScrim)
                .frame(maxWidth: .infinity, maxHeight: 64.0)
                .clipShape(RoundedRectangle(cornerRadius: 4.0))
                //            .border(.yellow)
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
        .onAppear {
            thumbnailModel.startExtractingThumbnail()
        }
    }
    
    private func statusLine(status: DirectUpload.TransportStatus?) -> String {
        guard let status = status, let progress = status.progress, let startTime = status.startTime, startTime > 0 else {
            return "missing status"
        }
        
        let totalTimeSecs = status.updatedTime - (status.startTime ?? 0)
        let totalTimeMs = Int64((totalTimeSecs) * 1000)
        let kbytesPerSec = (progress.completedUnitCount) / totalTimeMs // bytes/milli = kb/sec
        let fourSigs = NumberFormatter()
        fourSigs.minimumSignificantDigits = 4
        fourSigs.maximumSignificantDigits = 4
        let twoSigs = NumberFormatter()
        twoSigs.minimumSignificantDigits = 2
        twoSigs.maximumSignificantDigits = 2
        
        let formattedTime = twoSigs.string(for: totalTimeSecs) ?? ""
        let formattedDataRate = fourSigs.string(for: kbytesPerSec) ?? ""
        let formattedMBytes = twoSigs.string(for: progress.completedUnitCount / 1000 / 1000) ?? ""
        
        return "\(formattedMBytes) MB in \(formattedTime)s (\(formattedDataRate) KB/s)"
    }
    
    private func elapsedBytesOfTotal(status: DirectUpload.TransportStatus) -> String {
        guard let progress = status.progress else {
            return "unknown"
        }
        return "\(progress.completedUnitCount / 1000)KB"
    }
    
    init(upload: DirectUpload) {
        self.upload = upload
        _thumbnailModel = StateObject(
            wrappedValue: {
                ThumbnailModel(asset: AVAsset(url: upload.videoFile!), upload: upload)
            }()
        )
    }
}

fileprivate struct UploadListPlaceholderView: View {
    var body: some View {
        NavigationLink {
            CreateUploadView()
                .navigationBarHidden(true)
        } label: {
            ZStack(alignment: .top) {
                UploadCallToActionLabel()
                    .padding(EdgeInsets(top: 64, leading: 20, bottom: 0, trailing: 20))
            }
        }
    }
}

struct ListContent_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            WindowBackground
            UploadListContainerView()
        }
        .environmentObject(UploadListModel())
    }
}

struct EmptyList_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            WindowBackground
            UploadListPlaceholderView()
            
        }
    }
}

struct UploadListItem_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground
            let upload = DirectUpload(uploadURL: URL(string: "file:///")!, videoFileURL: URL(string: "file:///")!)
            ListItem(upload: upload)
        }
    }
}
