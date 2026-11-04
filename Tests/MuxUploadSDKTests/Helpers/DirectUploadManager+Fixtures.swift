import Foundation
@testable import MuxUploadSDK

func makeTestUploadManager() -> DirectUploadManager {
    let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    return DirectUploadManager(uploadActor: UploadCacheActor(persistence:
        UploadPersistence(innerFile: FakeUploadsFile.simiulatedStorage(), atURL: file)))
}
