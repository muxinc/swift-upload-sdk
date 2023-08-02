# Mux's Swift Upload SDK
This SDK makes it easy to upload videos for ingest to Mux from an iOS or iPadOS application. It handles large files by breaking them into chunks and uploading each chunk individually.

Each video is uploaded to an authenticated [upload URL created by a trusted backend server request to the Mux Video API](https://docs.mux.com/guides/video/upload-files-directly). **Do not include the secret API credentials to create an authenticated upload URL in your application.**

## Usage
To use this SDK, you'll need to add it as a dependency using either Swift Package Manager or Cocoapods.

## Documentation
API documentation available [here](https://muxinc.github.io/swift-upload-sdk/documentation/muxuploadsdk/).

A getting started guide can be found [here](https://docs.mux.com/guides/video/upload-video-directly-from-ios-or-ipados).

### Server-Side: Create a Direct Upload

If you haven't yet done so, you must create an [access token](https://docs.mux.com/guides/system/make-api-requests#http-basic-auth) to complete these steps.
To start an upload, you must first create an [upload URL](https://docs.mux.com/guides/video/upload-files-directly). Then, provide that direct-upload PUT URL to your app, so the app can begin the upload process.

### App-Side: Install the SDK
Add our SDK as a package dependency to your Xcode project.

#### Swift Package Manager
The Swift Package Manager is a tool for managing the distribution of Swift code. It's integrated with Xcode and the Swift build system to automate the process of downloading, compiling, and linking dependencies.

[Step-by-step guide on using Swift Package Manager in Xcode](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app). Our repository URL (for the 'search' field in the upper corner) is `https://github.com/muxinc/swift-upload-sdk`.

#### Cocoapods
Cocoapods is a dependency manager for Xcode project. See here for [usage instructions](https://guides.cocoapods.org/using/using-cocoapods.htm).
To integrate our SDK into your Xcode project using Cocoapods, specify it in your `Podfile` like so:

```ruby

pod 'Mux-Upload-SDK'

```

### App-Side: Start an Upload
To start an upload, you must first create an [upload URL](https://docs.mux.com/guides/video/upload-files-directly). Then, pass the upload URL and the file to be uploaded into the SDK.

```swift
import MuxUploadSDK

let directUploadURL: URL = /* Fetch the direct upload URL created before */
let videoInputURL: URL = /* File URL to your video file. See Test App for how to retrieve a video from PhotosKit */

let upload = DirectUpload(
    uploadURL: directUploadURL,
    inputFileURL: videoInputURL,
)

upload.progressHandler = { state in
    self.uploadScreenState = .uploading(state)
}

upload.resultHandler = { result in
    switch result {
    case .success(let success):
        self.uploadScreenState = .done(success)
        self.upload = nil
        NSLog("Upload Success!")
    case .failure(let error):
        self.uploadScreenState = .failure(error)
        NSLog("!! Upload error: \(error.localizedDescription)")
    }
}

self.upload = upload
upload.start()
```

A simple example of how to use the SDK in a realistic app can be found [here](https://github.com/muxinc/swift-upload-sdk/blob/main/Examples/)

## Development

This SDK is a swift package that can be opened by Xcode. To edit this SDK, clone it and open the root folder in Xcode.

This SDK has a sample/test app in the `TestApp/` folder. You can run/edit the sample app by opening `Example/SwiftUploadSDKExample/SwiftUploadSDKExample.xcodeproj`
