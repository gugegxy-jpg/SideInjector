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
        // 覆盖安装会更换数据容器路径：索引里记录的绝对路径会过期，
        // 必须重新落到当前容器，否则整库会被误判为「文件不存在」而清空。
        items = list.compactMap { item in
            let url = resolve(item)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            var m = item
            m.path = url.path
            return m
        }
        persist()
    }

    /// 优先当前容器的标准位置 → 索引里的原路径 → 按 `/Signed/` 之后的部分重定向到当前容器。
    private func resolve(_ item: SignedIPA) -> URL {
        let fm = FileManager.default
        let canonical = dir.appendingPathComponent("\(item.id.uuidString).ipa")
        if fm.fileExists(atPath: canonical.path) { return canonical }
        if fm.fileExists(atPath: item.path) { return URL(fileURLWithPath: item.path) }
        if let r = item.path.range(of: "/Signed/") {
            let rebased = dir.appendingPathComponent(String(item.path[r.upperBound...]))
            if fm.fileExists(atPath: rebased.path) { return rebased }
        }
        return canonical
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
        // 优先**硬链接**：库目录与产物都在 App 容器内（同一卷），链接是瞬时的、**不额外占空间**，
        // 两个文件名指向同一份数据（删掉任一路径都不影响另一路径存活）。
        // 之前一律 copyItem：每次成功流程都会把一个几百 MB～GB 的包整份复制一遍 ——
        // 主线程卡住、存储翻倍，纯属浪费。
        // 跨卷 / iCloud 未落地 / 文件系统不支持时才退回复制。
        let linked = (try? FileManager.default.linkItem(at: url, to: dst)) != nil
        if !linked {
            guard (try? FileManager.default.copyItem(at: url, to: dst)) != nil else { return nil }
        }

        let item = SignedIPA(id: id, name: cleanName, path: dst.path, createdAt: Date(), size: size)
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// 导入外部「已经签名好的」IPA（来自「文件」App / 分享等）：复制入库，随即可安装或再导出。
    /// 与 `add` 同样按「同名同大小」去重，因此重复导入同一个文件不会产生重复条目。
    @discardableResult
    func importExternal(_ url: URL) -> SignedIPA? {
        guard url.pathExtension.lowercased() == "ipa" else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return add(url: url, name: name.isEmpty ? "imported.ipa" : name)
    }

    func remove(_ item: SignedIPA) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: item.path))
        persist()
    }

    func url(for item: SignedIPA) -> URL { resolve(item) }
}
