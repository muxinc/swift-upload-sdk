//
//  BigUploadCta.swift
//  Test App
//
//  Created by Emily Dixon on 5/11/23.
//

import SwiftUI
import PhotosUI

struct BigUploadCTALabel: View {
    var body: some View {
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
        .frame(height: SwiftUploadSDKExample.THUMBNAIL_HEIGHT)
    }
}



struct BigUploadCTA_Preview: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            BigUploadCTALabel()
                .padding(EdgeInsets(top: 64, leading: 20, bottom: 0, trailing: 20))
        }
        .environmentObject(UploadCreationModel())
    }
}
