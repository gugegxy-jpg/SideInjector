import Foundation
import Combine

/// 一条已保存的开发证书（p12 + mobileprovision + 密码）。
struct SavedCert: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var p12Path: String
    var provPath: String
    var password: String
    var createdAt: Date
}

/// 证书库：把用户选择的 p12 / mobileprovision 复制进 App 沙盒并持久化，
/// 之后在首页下拉直接选用，无需每次重新选文件。
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([SavedCert].self, from: data) else { return }
        certs = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(certs) { try? data.write(to: indexURL) }
    }

    /// 保存一条证书；返回新证书（失败返回 nil）。
    @discardableResult
    func add(name: String, p12: URL, prov: URL, password: String) -> SavedCert? {
        let id = UUID()
        let folder = dir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p12Dst = folder.appendingPathComponent("cert.p12")
        let provDst = folder.appendingPathComponent("profile.mobileprovision")

        func copy(_ src: URL, _ dst: URL) -> Bool {
            let a = src.startAccessingSecurityScopedResource()
            defer { if a { src.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.removeItem(at: dst)
            return (try? FileManager.default.copyItem(at: src, to: dst)) != nil
        }

        guard copy(p12, p12Dst), copy(prov, provDst) else { return nil }

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
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(cert.id.uuidString, isDirectory: true))
        persist()
    }

    /// 编辑一条证书：名称/密码随时可改；p12 / 描述文件为 nil 时保持原文件不变。
    @discardableResult
    func update(id: UUID, name: String, password: String, p12: URL?, prov: URL?) -> SavedCert? {
        guard let idx = certs.firstIndex(where: { $0.id == id }) else { return nil }
        let folder = dir.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        func copy(_ src: URL, _ dst: URL) -> Bool {
            let a = src.startAccessingSecurityScopedResource()
            defer { if a { src.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.removeItem(at: dst)
            return (try? FileManager.default.copyItem(at: src, to: dst)) != nil
        }

        if let p12, !copy(p12, folder.appendingPathComponent("cert.p12")) { return nil }
        if let prov, !copy(prov, folder.appendingPathComponent("profile.mobileprovision")) { return nil }

        var cert = certs[idx]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { cert.name = trimmed }
        cert.password = password
        certs[idx] = cert
        persist()
        return cert
    }
}
