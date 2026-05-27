//
//  UploadControlStyles.swift
//  SwiftUploadSDKExample
//

import SwiftUI

extension Text {
    func controlButtonStyle() -> some View {
        font(.system(size: 14.0, weight: .bold))
            .foregroundColor(White)
            .padding(.horizontal, 14.0)
            .frame(height: 44.0)
            .background(Gray90.clipShape(RoundedRectangle(cornerRadius: 4.0)))
    }

    func primaryControlButtonStyle() -> some View {
        font(.system(size: 14.0, weight: .bold))
            .foregroundColor(White)
            .padding(.horizontal, 18.0)
            .frame(height: 44.0)
            .background(Green50.clipShape(RoundedRectangle(cornerRadius: 4.0)))
    }

    func uploadProgressTextStyle() -> some View {
        font(.system(size: 12.0, weight: .regular, design: .monospaced))
            .foregroundColor(Gray30)
    }
}
