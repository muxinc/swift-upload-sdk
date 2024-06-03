//
//  SelectVideoView.swift
//  SwiftUploadSDKExample
//

import PhotosUI
import SwiftUI

struct SelectVideoView: View {
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    @State var pickedItem: [PhotosPickerItem] = []

    var body: some View {
        VStack {
            PhotosPicker(
                selection: $uploadCreationModel.pickedItem,
                maxSelectionCount: 1,
                selectionBehavior: .default,
                matching: .videos,
                preferredItemEncoding: .current,
                photoLibrary: .shared(),
                label: {
                    UploadCallToActionLabel()
                }
            )
            .photosPickerAccessoryVisibility(
                .hidden,
                edges: .all
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

struct SelectVideoView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            SelectVideoView()
        }
        .environmentObject(UploadCreationModel())
    }
}
