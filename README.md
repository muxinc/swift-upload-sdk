# Mux's Swift Upload SDK
This SDK makes it easy to upload videos to Mux from an iOS app. It handles large files by breaking them into chunks and uploads each chunk individually. Each file that gets uploaded will get sent to an [upload URL created by a backend server](https://docs.mux.com/guides/video/upload-files-directly). **Do not include credentials to create an upload URL from an app.**

## Usage
To use this SDK, you must first add it as a dependency. The Mux Swift Upload SDK for iOS is available on SPM.

### Add Package Dependency
Add our SDK as a package dependency to your XCode project [with the following steps](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app). Our repository URL (for the 'search' field in the upper corner) is `https://github.com/muxinc/swift-upload-sdk`

### Start an Upload
To start an upload, you must first create an [upload URL](https://docs.mux.com/guides/video/upload-files-directly). Then, pass the upload URL and the file to be uploaded into the SDK.

```swift
let upload = MuxUpload(
    uploadURL: URL(string: PUT_URL)!,
    videoFileURL: videoFileURL,
    videoMIMEType: "video/*"
)

upload.progressHandler = { state in
    self.uploadScreenState = .uploading(state)
}

upload.resultHandler = { result in
    // TODO: Delete the temp file
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

A simple example usage can be found in our [Test App](https://github.com/muxinc/swift-upload-sdk/blob/main/apps/Test%20App/Test%20App/Screens/UploadScreenViewModel.swift)

## Development

This SDK is a swift package that can be opened by xcode. To edit this SDK, clone it and open the root folder in Xcode.

This SDK has a sample/test app in the `TestApp/` folder. You can run/edit the sample app by opening `apps/Test App/Upload Test App.xcodeproj`

## Known Issues

* Resumed uploads currently start over from the beginning of the file being uploaded.
