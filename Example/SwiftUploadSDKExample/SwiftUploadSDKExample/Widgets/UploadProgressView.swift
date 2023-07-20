//
//  UploadProgressView.swift
//  Test App
//
//  Created by Emily Dixon on 2/15/23.
//

import SwiftUI
import MuxUploadSDK

struct UploadProgressView: View {
    let appUploadState: AppUploadState
    let viewModel: UploadScreenViewModel
    
    var body: some View {
        HStack {
            VStack {
                Text(uploadStateTxt(uploadState: self.appUploadState))
                    .font(Font.headline)
                    .padding(.bottom, 12.0)
                ProgressView(
                    elapsedBytesTxt(uploadState: appUploadState),
                    value: uploadStatus(uploadState: appUploadState)?.progress?.fractionCompleted ?? 0.0
                )
                Text(dataRateTxt(status: uploadStatus(uploadState: appUploadState)))
            }
            Button {
                if viewModel.isPaused() {
                    viewModel.resumeUpload()
                } else {
                    viewModel.pauseUpload()
                }
            } label: {
                if viewModel.isPaused() {
                    Image(systemName: "play")
                } else {
                    Image(systemName: "pause")
                }
            }.padding(.all, 18.0)
        }
    }
    
    private func uploadStatus(uploadState: AppUploadState) -> MuxUpload.Status? {
        switch uploadState {
        case .done(let success): return success.finalState
        case .uploading(let status): return status
        default: return nil
        }
    }
    
    private func dataRateTxt(status: MuxUpload.Status?) -> String {
        guard let status = status, let progress = status.progress else {
            return ""
        }
        let totalTimeSecs = status.updatedTime - status.startTime
        let totalTimeMs = Int64((totalTimeSecs) * 1000)
        let kbytesPerSec = (progress.completedUnitCount) / totalTimeMs // bytes/milli = kb/sec
        let elapsedTimeFormatter = NumberFormatter()
        elapsedTimeFormatter.minimumSignificantDigits = 4
        elapsedTimeFormatter.maximumSignificantDigits = 4
        return "\(elapsedTimeFormatter.string(for: totalTimeSecs)!) sec elapsed. \(kbytesPerSec) Kb/s"
    }
    
    private func elapsedBytesTxt(uploadState: AppUploadState) -> String {
        switch uploadState {
        case .done(let success): return elapsedBytesOfTotal(status: success.finalState)
        case .uploading(let status): return elapsedBytesOfTotal(status: status)
        default: return "unkown"
        }
    }
    
    private func elapsedBytesOfTotal(status: MuxUpload.Status) -> String {
        guard let progress = status.progress else {
            return "unknown"
        }
        return "\(progress.completedUnitCount) / \(progress.totalUnitCount)"
    }
    
    private func uploadStateTxt(uploadState: AppUploadState) -> String {
        switch uploadState {
        case .uploading(_): return "uploading"
        case .not_started: return "not started"
        case .done(_): return "done!"
        case .preparing: return "preparing"
        case .failure(let err): return "error \(String(describing: err?.localizedDescription))"
        }
    }
}

struct UploadProgressView_Previews: PreviewProvider {
    static var previews: some View {
        UploadProgressView(
            appUploadState: .preparing,
            viewModel: UploadScreenViewModel()
        )
    }
}
