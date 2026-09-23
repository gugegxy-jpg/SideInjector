import Foundation

/// 存储统计与缓存清理。
///
/// 明确区分「缓存」与「数据」，避免清理误伤：
///   - **缓存**（可清）：`tmp/` 下本 App 的工作目录 —— `si_in_*`（导入的输入副本）、
///     `si_out_*`（解包后的工作树）、`si_export_*`（导出的成品 IPA）、`si_share_*`（导出用的临时副本）、
///     签名过程中临时产生的 `.si_signed` / `.si_nested`；以及 `Caches/`；
///   - **数据**（不清）：`Application Support/Certificates`（证书库）、`Signed`（已签名 IPA 库）、
///     `Inputs`（导入的 IPA / dylib）、`rp_pairing.plist`（配对文件）、`Logs`（日志，另有独立入口清）。
enum Storage {

    /// 判断 tmp 下的某一项是不是本 App 的缓存。
    private static func isCacheItem(_ url: URL) -> Bool {
        let n = url.lastPathComponent
        return n.hasPrefix("si_") || n.hasPrefix(".si_") || n.hasPrefix("signed_")
    }

    private static func tmpCacheURLs() -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                 includingPropertiesForKeys: nil)) ?? []
        return items.filter(isCacheItem)
    }

    /// 缓存明细（名字 → 字节数），按大小降序。
    static func cacheItems() -> [(name: String, bytes: Int64)] {
        var out: [(String, Int64)] = tmpCacheURLs().map { ($0.lastPathComponent, size(of: $0)) }
        if let caches = cachesURL(), let items = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil), !items.isEmpty {
            let n = items.reduce(Int64(0)) { $0 + size(of: $1) }
            if n > 0 { out.append(("Caches", n)) }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// 缓存总大小（字节）。
    static func cacheBytes() -> Int64 {
        cacheItems().reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// 清空缓存，返回释放的字节数。
    @discardableResult
    static func cleanCache() -> Int64 {
        let fm = FileManager.default
        let before = cacheBytes()
        for u in tmpCacheURLs() { try? fm.removeItem(at: u) }
        if let caches = cachesURL(),
           let items = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for u in items { try? fm.removeItem(at: u) }
        }
        return max(0, before - cacheBytes())
    }

    /// 递归统计文件 / 目录大小。
    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    private static func cachesURL() -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    /// 人类可读大小。
    static func human(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}
