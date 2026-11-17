# Mux Swift Upload SDK

This SDK makes it easy to upload videos for ingest to Mux from an iOS or iPadOS application. It handles large files by breaking them into chunks and uploading each chunk individually.

Each video is uploaded to an authenticated [upload URL created by a trusted backend server request to the Mux Video API](https://docs.mux.com/guides/video/upload-files-directly). **Do not include the secret API credentials to create an authenticated upload URL in your application.**

## Usage

To use this SDK, add it as a dependency using either Swift Package Manager or CocoaPods.

The Upload SDK supports iOS 15 and iPadOS 15 or later. macOS is not supported at this time.

## Documentation

See [Upload video directly from iOS or iPadOS](https://docs.mux.com/guides/video/upload-video-directly-from-ios-or-ipados) for the complete integration guide.

### Server-Side: Create a Direct Upload

If you haven't yet done so, create an [access token](https://docs.mux.com/guides/system/make-api-requests#http-basic-auth) for your trusted environment.
To start an upload, create a [Direct Upload](https://docs.mux.com/guides/video/upload-files-directly) there and provide its authenticated `PUT` URL to your app. Never embed your Mux access token ID or secret key in a production app.

### App-Side: Install the SDK

Add our SDK as a package dependency to your Xcode project.

#### Swift Package Manager

The Swift Package Manager is a tool for managing the distribution of Swift code. It's integrated with Xcode and the Swift build system to automate the process of downloading, compiling, and linking dependencies.

[Step-by-step guide on using Swift Package Manager in Xcode](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app). Our repository URL (for the 'search' field in the upper corner) is `https://github.com/muxinc/swift-upload-sdk`.

#### CocoaPods

CocoaPods is a dependency manager for Xcode projects. See the [CocoaPods usage instructions](https://guides.cocoapods.org/using/using-cocoapods.html).
To integrate our SDK into your Xcode project using CocoaPods, specify it in your `Podfile`:

```ruby
pod 'Mux-Upload-SDK'
```

### App-Side: Start an Upload

Pass the authenticated Direct Upload URL and a local video file URL to the SDK. Keep a strong reference to the upload while it is running if your app needs to control it later.

```swift
import Foundation
import MuxUploadSDK

final class UploadCoordinator {
    private var upload: DirectUpload?

    func startUpload(uploadURL: URL, videoFileURL: URL) {
        let upload = DirectUpload(
            uploadURL: uploadURL,
            inputFileURL: videoFileURL
        )

        upload.progressHandler = { state in
            guard let progress = state.progress else { return }
            print("Uploaded \(progress.completedUnitCount) / \(progress.totalUnitCount)")
        }

        upload.resultHandler = { [weak self] result in
            switch result {
            case .success:
                print("Upload succeeded")
            case .failure(let error):
                print("Upload failed: \(error.localizedDescription)")
            }
            self?.upload = nil
        }

        self.upload = upload
        upload.start()
    }
}
```

### Resuming uploads

- Keep the original video unchanged in Application Support or Documents until the upload succeeds. The SDK uploads that file directly when no conversion is needed (including eligible HDR preservation) or conversion falls back; `tmp` can be purged.
- Before starting, persist your own pending-upload record with the backend Direct Upload ID and a durable reference to the original file. SDK checkpoints begin only when sending begins, not during conversion.
- At launch, register a `DirectUploadManagerDelegate`, then call `resumeAllDirectUploads()`. Wait for its delegate update before starting new uploads or doing other manager operations; attach handlers and `start()` restored uploads that are neither in progress nor complete. Checkpoints are saved during transport; do not rely on `applicationWillTerminate` being called.

```swift
import MuxUploadSDK

final class UploadRestorer: DirectUploadManagerDelegate {
    func restoreAtLaunch() {
        DirectUploadManager.shared.addDelegate(self)
        DirectUploadManager.shared.resumeAllDirectUploads()
    }
    func didUpdate(managedDirectUploads uploads: [DirectUpload]) {
        DirectUploadManager.shared.removeDelegate(self)
        for upload in uploads where !upload.inProgress && !upload.complete {
            // Attach your progress/result handlers before starting.
            upload.start()
        }
        // Now allow new uploads, including when the restored list is empty.
    }
}
```

- Use the restored handle; never create a new `DirectUpload` with a URL that may already have received bytes. Preparing a new payload for that URL can corrupt the upload or cause it to fail.
- After a failure in the same session, `await DirectUploadManager.shared.resumeDirectUpload(ofFile: originalURL)`, attach handlers to the returned handle, and call `start()`. Calling `start()` on the failed handle does not retry it. File-based lookup prefers an active or newest session: keep one pending upload per original file when using this retry pattern.
- Saved checkpoints expire after three days since their last update. If a pending upload is not restored, lookup returns `nil`, or the upload reports that its saved file is missing, check its status through your backend. If it has not completed, request a new Direct Upload URL and start a new upload from the original; do not reuse the old URL.
- Set the backend Direct Upload [`timeout`](https://www.mux.com/docs/api-reference/video/direct-uploads/create-direct-upload) for the expected interruption window (default one hour; maximum seven days). Resume requires a still-valid upload in `waiting` status and an SDK checkpoint within its separate three-day retention window.

### Configure Input Standardization

Input standardization is enabled by default and is best effort. The SDK uploads compliant H.264 and HEVC inputs without re-encoding them. When local inspection, conversion, or validation cannot complete, the SDK uploads the original input by default so that Mux can process it.

The default maximum resolution is 1920 x 1080 (1080p), and eligible HDR input is preserved. To prepare video up to 3840 x 2160 (2160p/4K), provide custom options:

```swift
import MuxUploadSDK

let options = DirectUploadOptions(
    inputStandardization: .init(
        maximumResolution: .preset3840x2160,
        hdrHandling: .preserve
    )
)
```

Selecting 1440p or 2160p in the SDK controls the file prepared on the device. When your trusted environment creates the Direct Upload, also set `new_asset_settings.max_resolution_tier` to the matching `"1440p"` or `"2160p"` tier.

Preserving HDR does not guarantee end-to-end HDR playback. To create BT.709 SDR output on the device for supported HDR inputs, explicitly select `.toneMapToSDR`. See the [integration guide](https://docs.mux.com/guides/video/upload-video-directly-from-ios-or-ipados#handling-hdr-input) for supported behavior, fallback handling, and examples.

A sample app showing input-standardization configuration, PhotosPicker integration, upload progress, cancellation, and managed-upload restoration is available in [`Example/SwiftUploadSDKExample`](Example/SwiftUploadSDKExample/).

## Development

This SDK is a Swift package that can be opened by Xcode. To edit it, clone this repository and open the root folder in Xcode.

Run or edit the sample app by opening `Example/SwiftUploadSDKExample/SwiftUploadSDKExample.xcodeproj`.

## Releasing

Maintainer release instructions live in [RELEASING.md](RELEASING.md).
