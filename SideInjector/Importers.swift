import SwiftUI
import UniformTypeIdentifiers

/// 弹出「文件」App 选择文件（可多选），回调绝对 URL 数组。
final class DocumentPicker: UIDocumentPickerViewController, UIDocumentPickerDelegate {
    private let onPick: ([URL]) -> Void

    init(types: [UTType] = [.init(filenameExtension: "ipa")!,
                            .init(filenameExtension: "dylib")!,
                            .init(filenameExtension: "p12")!,
                            .init(filenameExtension: "mobileprovision")!,
                            .data],
         allowsMultiple: Bool = false,
         onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
        super.init(forOpeningContentTypes: types, asCopy: true)
        self.delegate = self
        self.allowsMultipleSelection = allowsMultiple
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        // asCopy 已把文件复制进沙盒，这里直接回传。
        onPick(urls)
    }
}
