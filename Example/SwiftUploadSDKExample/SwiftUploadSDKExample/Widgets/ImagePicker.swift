import PhotosUI
import SwiftUI

struct ImagePicker: UIViewControllerRepresentable {
    let pickerConfiguration: PHPickerConfiguration
    let delegate: PickerResultHandler
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        let picker = PHPickerViewController(configuration: pickerConfiguration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    typealias PickerResultHandler = ([PHPickerResult]) -> Void
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            parent.delegate(results)
        }
    }
}
