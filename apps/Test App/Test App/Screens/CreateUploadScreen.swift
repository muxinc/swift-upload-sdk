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
                MuxNavBar(title: "Create a New Upload")
                ScreenContent(exportState: uploadCreationVM.exportState)
            }
        }
    }
    
    @EnvironmentObject var uploadCreationVM: UploadCreationViewModel
}

fileprivate struct ScreenContent: View {
    var body: some View {
        ZStack {
            WindowBackground
            // TODO: If we have a thumbnail loaded, that's what we want to show
            switch exportState {
            case .not_started: EmptyView()
            case .preparing: EmptyView() // TODO
            case .failure(let error): ErrorView(error: error)
            case .ready(let (image, url)): EmptyView() // TODO
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
            .frame(height: 228)
            
            Spacer()
        }
    }
    
    let error: Error?
    
    init(error: Error? = nil) {
        self.error = error
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
            .frame(height: 228)
            
            Spacer()
        }
    }
}

fileprivate struct EmptyView: View {
    var body: some View {
        VStack {
            BigUploadCTA()
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

struct ContentContainer_Previews: PreviewProvider {
    static var previews: some View {
        let exportState = ExportState.failure(nil)
        ScreenContent(exportState: exportState)
            .environmentObject(UploadCreationViewModel())
    }
}

struct CreateUploadScreen_Previews: PreviewProvider {
    static var previews: some View {
        CreateUploadScreen()
            .environmentObject(UploadScreenViewModel())
            .environmentObject(UploadCreationViewModel())
    }
}

struct EmptyView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            EmptyView()
        }
        .environmentObject(UploadScreenViewModel())
        .environmentObject(UploadCreationViewModel())
    }
}

struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ErrorView()
        }
        .environmentObject(UploadScreenViewModel())
        .environmentObject(UploadCreationViewModel())
    }
}

struct ProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ProcessingView()
        }
        .environmentObject(UploadScreenViewModel())
        .environmentObject(UploadCreationViewModel())
    }
}
