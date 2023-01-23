//
//  UploadingView.swift
//  Test App
//
//  Created by Emily Dixon on 2/15/23.
//

import Foundation
import SwiftUI

struct UploadingView : View {
    let state: ItemState
    let progressPercent: Float
    
    var body: some View {
        VStack {
        }
    }
    
    enum ItemState {
        case done, not_done
    }
}
