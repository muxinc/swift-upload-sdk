//
//  UploadListPlaceholderView.swift
//  SwiftUploadSDKExample
//

import SwiftUI

struct UploadListPlaceholderView: View {
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

struct UploadListPlaceholderView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack(alignment: .top) {
            WindowBackground
            UploadListPlaceholderView()

        }
    }
}
