//
//  Theme.swift
//  Test App
//
//  Created by Emily Dixon on 2/15/23.
//

import Foundation
import SwiftUI

/// Theme for buttons with important calls to action
struct CtaButtonStyle : ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(Rectangle().fill(.blue))
            .foregroundColor(.white)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 1.2 : 1)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

