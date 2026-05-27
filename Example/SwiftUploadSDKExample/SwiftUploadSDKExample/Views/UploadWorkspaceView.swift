//
//  UploadWorkspaceView.swift
//  SwiftUploadSDKExample
//

import MuxUploadSDK
import PhotosUI
import SwiftUI

struct UploadWorkspaceView: View {
    @EnvironmentObject var uploadCreationModel: UploadCreationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20.0) {
            preview
            status
            controls
        }
        .padding(.horizontal, 20.0)
        .padding(.top, 32.0)
    }

    @ViewBuilder
    private var preview: some View {
        switch uploadCreationModel.workflowState {
        case .ready(let preparedUpload),
             .uploading(_, _, let preparedUpload),
             .restoring(let preparedUpload),
             .restoreFailed(_, let preparedUpload),
             .completed(_, let preparedUpload):
            UploadPreview(thumbnail: preparedUpload.thumbnail)
        case .preparing:
            UploadPreview(thumbnail: nil) {
                ProgressView()
                    .tint(Green50)
            }
        case .preparationFailed:
            UploadPreview(thumbnail: nil) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34.0, weight: .semibold))
                    .foregroundColor(Green50)
            }
        case .idle:
            videoPicker {
                UploadCallToActionLabel()
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8.0) {
            Text(title)
                .font(.system(size: 18.0, weight: .bold))
                .foregroundColor(White)
            Text(detail)
                .font(.system(size: 13.0, weight: .regular))
                .foregroundColor(Gray30)
            if shouldShowProgress {
                uploadProgress
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var uploadProgress: some View {
        switch uploadCreationModel.workflowState {
        case .uploading(_, nil, _):
            HStack(spacing: 8.0) {
                ProgressView()
                    .tint(Green50)
                Text(progressText)
                    .uploadProgressTextStyle()
            }
        case .uploading(_, .some(let status), _) where status.progress != nil:
            ProgressView(value: status.progress?.fractionCompleted ?? 0.0)
                .progressViewStyle(.linear)
                .tint(Green50)
            Text(progressText)
                .uploadProgressTextStyle()
        case .uploading:
            HStack(spacing: 8.0) {
                ProgressView()
                    .tint(Green50)
                Text(progressText)
                    .uploadProgressTextStyle()
            }
        case .idle, .preparing, .preparationFailed, .ready, .restoring, .restoreFailed, .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12.0) {
            switch uploadCreationModel.workflowState {
            case .uploading:
                Button {
                    uploadCreationModel.resetSelection()
                } label: {
                    Text("Cancel")
                        .controlButtonStyle()
                }
            case .completed(.failure(_), let preparedUpload),
                 .restoreFailed(_, let preparedUpload):
                Button {
                    uploadCreationModel.resumeManagedUpload(for: preparedUpload)
                } label: {
                    Text("Resume upload")
                        .primaryControlButtonStyle()
                }
                videoPicker {
                    Text("Upload another video")
                        .controlButtonStyle()
                }
            case .completed(.success, _):
                videoPicker {
                    Text("Upload another video")
                        .primaryControlButtonStyle()
                }
            case .preparing, .ready, .preparationFailed:
                videoPicker {
                    Text("Change video")
                        .controlButtonStyle()
                }
            case .idle, .restoring, .completed:
                EmptyView()
            }

            if case .ready = uploadCreationModel.workflowState {
                Button {
                    uploadCreationModel.startPreparedUpload()
                } label: {
                    Text("Upload")
                        .primaryControlButtonStyle()
                }
            }
        }
    }

    private var title: String {
        switch uploadCreationModel.workflowState {
        case .idle:
            return "Select a video"
        case .preparing:
            return "Preparing video"
        case .preparationFailed:
            return "Video preparation failed"
        case .ready:
            return "Ready to upload"
        case .uploading(_, nil, _):
            return "Preparing upload"
        case .uploading:
            return "Uploading"
        case .restoring:
            return "Looking for resumable upload"
        case .restoreFailed:
            return "Resume unavailable"
        case .completed(let result, _):
            switch result {
            case .success:
                return "Upload complete"
            case .failure:
                return "Upload failed"
            }
        }
    }

    private var detail: String {
        switch uploadCreationModel.workflowState {
        case .idle:
            return "Choose one video from Photos to create a local upload file."
        case .preparing:
            return "Copying or exporting the selected video, creating a direct upload URL, and generating a thumbnail."
        case .preparationFailed(let error):
            return error.localizedDescription
        case .ready:
            return "Selected video is ready."
        case .uploading(_, nil, _):
            return "Inspecting the selected video and starting network upload."
        case .uploading:
            return "Uploading selected video."
        case .restoring:
            return "Checking the SDK-managed upload cache for this local video file."
        case .restoreFailed(let message, _):
            return message
        case .completed(let result, _):
            switch result {
            case .success:
                return "Your video has been uploaded."
            case .failure(let error):
                return error.localizedDescription
            }
        }
    }

    private var shouldShowProgress: Bool {
        switch uploadCreationModel.workflowState {
        case .uploading:
            return true
        case .idle, .preparing, .preparationFailed, .ready, .restoring, .restoreFailed, .completed:
            return false
        }
    }

    private var progressText: String {
        let status: DirectUpload.TransportStatus?
        switch uploadCreationModel.workflowState {
        case .uploading(_, let uploadStatus, _):
            status = uploadStatus
        case .idle, .preparing, .preparationFailed, .ready, .restoring, .restoreFailed, .completed:
            return ""
        }

        guard let status,
              let progress = status.progress,
              let startTime = status.startTime,
              startTime > 0 else {
            return "Preparing upload..."
        }

        let totalTimeSecs = max(status.updatedTime - startTime, 0.001)
        let bytesPerSecond = Double(progress.completedUnitCount) / totalTimeSecs
        let kilobytesPerSecond = bytesPerSecond / 1000.0
        let completedMegabytes = Double(progress.completedUnitCount) / 1_000_000.0
        let totalMegabytes = Double(progress.totalUnitCount) / 1_000_000.0

        let seconds = Self.shortNumberFormatter.string(for: totalTimeSecs) ?? "\(totalTimeSecs)"
        let completed = Self.shortNumberFormatter.string(for: completedMegabytes) ?? "\(completedMegabytes)"
        let total = Self.shortNumberFormatter.string(for: totalMegabytes) ?? "\(totalMegabytes)"
        let rate = Self.rateNumberFormatter.string(for: kilobytesPerSecond) ?? "\(kilobytesPerSecond)"

        return "\(completed) / \(total) MB in \(seconds)s (\(rate) KB/s)"
    }

    private func videoPicker<Label: View>(
        @ViewBuilder label: () -> Label
    ) -> some View {
        PhotosPicker(
            selection: $uploadCreationModel.pickedItem,
            maxSelectionCount: 1,
            selectionBehavior: .default,
            matching: .videos,
            preferredItemEncoding: .current,
            photoLibrary: .shared()
        ) {
            label()
        }
    }

    private static let shortNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumSignificantDigits = 2
        formatter.maximumSignificantDigits = 2
        return formatter
    }()

    private static let rateNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumSignificantDigits = 4
        formatter.maximumSignificantDigits = 4
        return formatter
    }()
}
