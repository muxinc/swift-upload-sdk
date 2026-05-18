//
//  UploadPreview.swift
//  SwiftUploadSDKExample
//

import SwiftUI

struct UploadPreview<Overlay: View>: View {
    let thumbnail: CGImage?
    let overlay: Overlay

    init(
        thumbnail: CGImage?,
        @ViewBuilder overlay: () -> Overlay = { EmptyView() }
    ) {
        self.thumbnail = thumbnail
        self.overlay = overlay()
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 4.0)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                        .foregroundColor(Gray30)
                        .background(
                            Image(
                                thumbnail,
                                scale: 1.0,
                                label: Text("")
                            )
                            .resizable()
                            .scaledToFill()
                            .frame(
                                maxWidth: proxy.size.width,
                                maxHeight: proxy.size.height,
                                alignment: .center
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 4.0))
                        )
                }
            } else {
                RoundedRectangle(cornerRadius: 4.0)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.0))
                    .foregroundColor(Gray30)
                    .background(Gray90.clipShape(RoundedRectangle(cornerRadius: 4.0)))
            }
            overlay
        }
        .frame(height: SwiftUploadSDKExample.thumbnailHeight)
    }
}
