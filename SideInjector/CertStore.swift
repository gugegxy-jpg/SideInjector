import Foundation
import Combine

/// 一条已保存的开发证书（p12 + mobileprovision + 密码）。
struct SavedCert: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// 下面两个字段只为兼容旧索引而保留。
    /// **不要直接使用它们**：请用 `CertStore.p12URL(for:)` / `provURL(for:)`，
    /// 因为覆盖安装可能更换数据容器路径，写死的绝对路径会失效（证书「丢失」的根因）。
    var p12Path: String
    var provPath: String
    var password: String
    var createdAt: Date
}

/// 证书库：把用户选择的 p12 / mobileprovision 复制进 App 沙盒并持久化，
/// 之后在首页下拉直接选用，无需每次重新选文件。
///
/// 路径策略（重要）：
///   文件固定放在 `Application Support/Certificates/<id>/cert.p12` 与 `profile.mobileprovision`，
///   读取时**按 id 重新推导**。iOS 在覆盖安装/更新时会把数据容器迁移到新的 UUID 路径，
///   索引文件会一起搬过去，但里面记录的绝对路径会过期 —— 推导 + 迁移即可自愈。
final class CertStore: ObservableObject {
    static let shared = CertStore()

    @Published private(set) var certs: [SavedCert] = []

    private let dir: URL
    private let indexURL: URL

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        dir = base.appendingPathComponent("Certificates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        indexURL = dir.appendingPathComponent("certs.json")
        load()
    }

    // MARK: - 路径推导

    private func folder(_ id: UUID) -> URL {
        dir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func canonicalP12(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("cert.p12")
    }

    private func canonicalProv(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("profile.mobileprovision")
    }

    /// 依次尝试：当前容器的标准位置 → 索引里记录的旧绝对路径 → 按 `/Certificates/`
    /// 之后的部分重定向到当前容器（覆盖安装换了容器 UUID 时的兜底）。
    /// 只要在别处找到文件，就顺手搬到标准位置，之后不再依赖旧路径。
    private func resolve(_ stored: String, canonical: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: canonical.path) { return canonical }

        if !stored.isEmpty, fm.fileExists(atPath: stored) {
            let old = URL(fileURLWithPath: stored)
            if (try? fm.copyItem(at: old, to: canonical)) != nil { return canonical }
            return old
        }

        if let r = stored.range(of: "/Certificates/") {
            let rebased = dir.appendingPathComponent(String(stored[r.upperBound...]))
            if fm.fileExists(atPath: rebased.path) {
                if (try? fm.copyItem(at: rebased, to: canonical)) != nil { return canonical }
                return rebased
            }
        }
        return canonical
    }

    /// 该证书当前可用的 P12 路径（永远用它，不要读 cert.p12Path）。
    func p12URL(for cert: SavedCert) -> URL {
        resolve(cert.p12Path, canonical: canonicalP12(cert.id))
    }

    /// 该证书当前可用的描述文件路径（永远用它，不要读 cert.provPath）。
    func provURL(for cert: SavedCert) -> URL {
        resolve(cert.provPath, canonical: canonicalProv(cert.id))
    }

    /// 两个文件是否都还在（用于提示用户「编辑重新选择」而不是一脸茫然）。
    func isUsable(_ cert: SavedCert) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: p12URL(for: cert).path)
            && fm.fileExists(atPath: provURL(for: cert).path)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SavedCert].self, from: data) else { return }
        // 读入即归位：把过期的绝对路径换成当前容器的可用路径，并写回索引。
        certs = list.map { c in
            var m = c
            m.p12Path = p12URL(for: c).path
            m.provPath = provURL(for: c).path
            return m
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(certs) { try? data.write(to: indexURL) }
    }

    /// 原子式复制：先写 `<目标>.tmp` 再替换。
    /// 避免「复制失败却已经删掉旧文件」把原本好用的证书弄坏。
    private func copy(_ src: URL, _ dst: URL) -> Bool {
        let fm = FileManager.default
        let a = src.startAccessingSecurityScopedResource()
        defer { if a { src.stopAccessingSecurityScopedResource() } }
        let tmp = dst.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        guard (try? fm.copyItem(at: src, to: tmp)) != nil else { return false }
        try? fm.removeItem(at: dst)
        return (try? fm.moveItem(at: tmp, to: dst)) != nil
    }

    // MARK: - 增删改

    /// 保存一条证书；返回新证书（失败返回 nil）。
    @discardableResult
    func add(name: String, p12: URL, prov: URL, password: String) -> SavedCert? {
        let id = UUID()
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)

        let p12Dst = canonicalP12(id)
        let provDst = canonicalProv(id)
        guard copy(p12, p12Dst), copy(prov, provDst) else {
            try? FileManager.default.removeItem(at: folder(id))
            return nil
        }

        let cert = SavedCert(id: id,
                             name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "未命名证书" : name,
                             p12Path: p12Dst.path,
                             provPath: provDst.path,
                             password: password,
                             createdAt: Date())
        certs.append(cert)
        persist()
        return cert
    }

    func remove(_ cert: SavedCert) {
        certs.removeAll { $0.id == cert.id }
        try? FileManager.default.removeItem(at: folder(cert.id))
        persist()
    }

    /// 编辑一条证书：名称/密码随时可改；p12 / 描述文件为 nil 时保持原文件不变。
    /// 关键：无论是否替换文件，都把记录里的路径重新写成**当前容器**的标准路径，
    /// 否则覆盖安装换了容器后，编辑永远修不好这张证书。
    @discardableResult
    func update(id: UUID, name: String, password: String, p12: URL?, prov: URL?) -> SavedCert? {
        guard let idx = certs.firstIndex(where: { $0.id == id }) else { return nil }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)

        let p12Dst = canonicalP12(id)
        let provDst = canonicalProv(id)
        if let p12, !copy(p12, p12Dst) { return nil }
        if let prov, !copy(prov, provDst) { return nil }

        var cert = certs[idx]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { cert.name = trimmed }
        cert.password = password
        cert.p12Path = p12Dst.path
        cert.provPath = provDst.path
        certs[idx] = cert
        persist()
        return cert
    }
}
