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
        switch uploadCreationModel.exportState {
        case .ready(let preparedUpload):
            UploadPreview(thumbnail: preparedUpload.thumbnail)
        case .preparing:
            UploadPreview(thumbnail: nil) {
                ProgressView()
                    .tint(Green50)
            }
        case .failure:
            UploadPreview(thumbnail: nil) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34.0, weight: .semibold))
                    .foregroundColor(Green50)
            }
        case .not_started:
            PhotosPicker(
                selection: $uploadCreationModel.pickedItem,
                maxSelectionCount: 1,
                selectionBehavior: .default,
                matching: .videos,
                preferredItemEncoding: .current,
                photoLibrary: .shared()
            ) {
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
        if uploadCreationModel.isStartingUpload && uploadCreationModel.uploadProgress == nil {
            HStack(spacing: 8.0) {
                ProgressView()
                    .tint(Green50)
                Text(progressText)
                    .uploadProgressTextStyle()
            }
        } else {
            ProgressView(
                value: uploadCreationModel.uploadProgress?.progress?.fractionCompleted ?? 0
            )
            .progressViewStyle(.linear)
            .tint(Green50)
            Text(progressText)
                .uploadProgressTextStyle()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch uploadCreationModel.photosAuthStatus {
        case .cant_auth:
            EmptyView()
        case .notDetermined, .authorized, .can_auth:
            HStack(spacing: 12.0) {
                if canCancelUpload {
                    Button {
                        uploadCreationModel.resetSelection()
                    } label: {
                        Text("Cancel")
                            .controlButtonStyle()
                    }
                } else if canChangeVideo {
                    PhotosPicker(
                        selection: $uploadCreationModel.pickedItem,
                        maxSelectionCount: 1,
                        selectionBehavior: .default,
                        matching: .videos,
                        preferredItemEncoding: .current,
                        photoLibrary: .shared()
                    ) {
                        Text("Change video")
                            .controlButtonStyle()
                    }
                }

                if canUpload {
                    Button {
                        uploadCreationModel.startPreparedUpload()
                    } label: {
                        Text("Upload")
                            .primaryControlButtonStyle()
                    }
                }
            }
        }
    }

    private var title: String {
        if let uploadResult = uploadCreationModel.uploadResult {
            switch uploadResult {
            case .success:
                return "Upload complete"
            case .failure:
                return "Upload failed"
            }
        }

        if uploadCreationModel.isStartingUpload {
            return "Preparing upload"
        }

        if isUploadActive {
            return "Uploading"
        }

        switch uploadCreationModel.exportState {
        case .not_started:
            return "Select a video"
        case .preparing:
            return "Preparing video"
        case .ready:
            return "Ready to upload"
        case .failure:
            return "Video preparation failed"
        }
    }

    private var detail: String {
        if let uploadErrorMessage = uploadCreationModel.uploadErrorMessage {
            return uploadErrorMessage
        }

        if case .success? = uploadCreationModel.uploadResult {
            return "Your video has been uploaded."
        }

        if uploadCreationModel.isStartingUpload {
            return "Inspecting the selected video and starting network upload."
        }

        if isUploadActive {
            return "Uploading selected video."
        }

        switch uploadCreationModel.exportState {
        case .not_started:
            return "Choose one video from Photos to create a local upload file."
        case .preparing:
            return "Copying or exporting the selected video, creating a direct upload URL, and generating a thumbnail."
        case .ready:
            return "Selected video is ready."
        case .failure(let error):
            return error.localizedDescription
        }
    }

    private var canCancelUpload: Bool {
        uploadCreationModel.isStartingUpload ||
        isUploadActive
    }

    private var canChangeVideo: Bool {
        // TODO: Re-enable changing videos after upload completion when we add richer sample-app controls.
        guard uploadCreationModel.uploadResult == nil else {
            return false
        }
        guard uploadCreationModel.currentUpload == nil else {
            return false
        }

        switch uploadCreationModel.exportState {
        case .preparing, .ready, .failure:
            return true
        case .not_started:
            return false
        }
    }

    private var canUpload: Bool {
        guard case .ready = uploadCreationModel.exportState else {
            return false
        }
        guard uploadCreationModel.currentUpload == nil else {
            return false
        }
        guard uploadCreationModel.uploadResult == nil else {
            return false
        }
        return true
    }

    private var shouldShowProgress: Bool {
        uploadCreationModel.uploadProgress != nil ||
        uploadCreationModel.isStartingUpload ||
        isUploadActive ||
        uploadCreationModel.uploadResult != nil
    }

    private var isUploadActive: Bool {
        uploadCreationModel.currentUpload != nil &&
        uploadCreationModel.uploadResult == nil
    }

    private var progressText: String {
        if uploadCreationModel.isStartingUpload && uploadCreationModel.uploadProgress == nil {
            return "Preparing upload..."
        }

        guard let status = uploadCreationModel.uploadProgress,
              let progress = status.progress,
              let startTime = status.startTime,
              startTime > 0 else {
            return "Waiting for upload progress"
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
