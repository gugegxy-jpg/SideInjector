import SwiftUI
import Combine

final class LogStore: ObservableObject {
    static let shared = LogStore()
    @Published var text: String = ""

    func append(_ s: String) {
        DispatchQueue.main.async {
            self.text += s + "\n"
        }
    }

    func clear() {
        DispatchQueue.main.async { self.text = "" }
    }
}
