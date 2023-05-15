//
//  UploadListScreen.swift
//  Test App
//
//  Created by Emily Dixon on 5/15/23.
//

import SwiftUI
import MuxUploadSDK

struct UploadListScreen: View {
    @EnvironmentObject var uploadListVM: UploadListViewModel
    
    var body: some View {
        ZStack(alignment: .top) {
            WindowBackground
            ListContianer(uploadList: [])
        }
    }
}

fileprivate struct ListContianer: View {
    var body: some View {
        if uploadList.isEmpty {
            EmptyList()
        } else {
            Text("TODO")
        }
    }
    
    private let uploadList: [MuxUpload]
    
    init(uploadList: [MuxUpload]) {
        self.uploadList = uploadList
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
            ListContianer(uploadList: [])
        }
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
        UploadListScreen()
            .environmentObject(UploadListViewModel())
    }
}
