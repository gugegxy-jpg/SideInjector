import Foundation
import Combine

/// 一条已签名的 IPA（持久化到 App 沙盒，可随时点击直接安装）。
struct SignedIPA: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var path: String
    var createdAt: Date
    var size: Int64

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 已签名 IPA 库：签名打包成功后自动入库；列表点击即可直接安装。
final class IPALibrary: ObservableObject {
    static let shared = IPALibrary()

    @Published private(set) var items: [SignedIPA] = []

    private let dir: URL
    private let indexURL: URL

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("Signed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("index.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SignedIPA].self, from: data) else { return }
        items = list.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL) }
    }

    /// 入库一个已签名 IPA。同名同大小视为已存在，直接返回（避免续跑时重复入库）。
    @discardableResult
    func add(url: URL, name: String) -> SignedIPA? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "signed.ipa" : name

        if let existing = items.first(where: { $0.name == cleanName && $0.size == size }) {
            return existing
        }

        let id = UUID()
        let dst = dir.appendingPathComponent("\(id.uuidString).ipa")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: url, to: dst)) != nil else { return nil }

        let item = SignedIPA(id: id, name: cleanName, path: dst.path, createdAt: Date(), size: size)
        items.insert(item, at: 0)
        persist()
        return item
    }

    func remove(_ item: SignedIPA) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.path))
        persist()
    }

    func url(for item: SignedIPA) -> URL { URL(fileURLWithPath: item.path) }
}
