//
//  UploadListScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/15/23.
//

import SwiftUI
import MuxUploadSDK
import AVFoundation

struct UploadListScreen: View {
    @EnvironmentObject var uploadListVM: UploadListViewModel
    
    var body: some View {
        ZStack(alignment: .top) {
            WindowBackground
            ListContianer()
        }
    }
}

fileprivate struct ListContianer: View {
    
    @EnvironmentObject var listVM: UploadListViewModel
    
    var body: some View {
        if listVM.lastKnownUploads.isEmpty {
            EmptyList()
        } else {
            LazyVStack {
                ForEach(listVM.lastKnownUploads, id: \.self) { upload in
                    ListItem(upload: upload)
                }
            }
        }
    }
}

fileprivate struct ListItem: View {
    
    @StateObject var uploadItemVM: UploadItemViewModel
    let upload: MuxUpload
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = uploadItemVM.thumbnail {
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
            // TODO: Only when the upload is in-progress
            ZStack {
                TransparentScrim
                if let status = uploadItemVM.uploadProgress {
                    
                } else {
                    Text("missing status")
                        .foregroundColor(White)
                }
                
            }
            .frame(maxWidth: .infinity, maxHeight: 64.0)
            .border(.yellow)
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
        .onAppear {
            uploadItemVM.startExtractingThumbnail()
        }
    }
    
    init(upload: MuxUpload) {
        self.upload = upload
        _uploadItemVM = StateObject(
            wrappedValue: {
                UploadItemViewModel(asset: AVAsset(url: upload.videoFile), upload: upload)
            }()
        )
    }
}

fileprivate struct EmptyList: View {
    var body: some View {
        NavigationLink {
            CreateUploadScreen()
                .navigationBarHidden(true)
        } label: {
            ZStack(alignment: .top) {
                BigUploadCTA()
                    .padding(EdgeInsets(top: 64, leading: 20, bottom: 0, trailing: 20))
            }
        }
    }
}

struct ListContent_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            WindowBackground
            ListContianer()
        }
        .environmentObject(UploadListViewModel())
    }
}

struct EmptyList_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            WindowBackground
            EmptyList()
            
        }
    }
}

struct UploadListItem_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground
            let upload = MuxUpload(uploadURL: URL(string: "file:///")!, videoFileURL: URL(string: "file:///")!)
            ListItem(upload: upload)
        }
    }
}
