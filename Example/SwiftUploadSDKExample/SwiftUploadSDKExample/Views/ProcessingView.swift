//
//  ProcessingView.swift
//  SwiftUploadSDKExample
//

import SwiftUI

struct ProcessingView: View {
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

struct ProcessingView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            WindowBackground.ignoresSafeArea()
            ProcessingView()
        }
        .environmentObject(UploadCreationModel())
    }
}

