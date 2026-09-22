import SwiftUI
import UniformTypeIdentifiers

/// 弹出「文件」App 选择单个文件，回调绝对 URL。
final class DocumentPicker: UIDocumentPickerViewController, UIDocumentPickerDelegate {
    private let onPick: (URL) -> Void

    init(types: [UTType] = [.init(filenameExtension: "ipa")!,
                            .init(filenameExtension: "dylib")!,
                            .init(filenameExtension: "p12")!,
                            .init(filenameExtension: "mobileprovision")!,
                            .data],
         onPick: @escaping (URL) -> Void) {
        self.onPick = onPick
        super.init(forOpeningContentTypes: types, asCopy: true)
        self.delegate = self
        self.allowsMultipleSelection = false
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        if let u = urls.first {
            // 复制进沙盒后也能访问；这里直接回传（asCopy 已复制）
            onPick(u)
        }
    }
}
