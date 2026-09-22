import SwiftUI
import Combine

final class Model: ObservableObject {
    static let shared = Model()

    // 证书 / 描述文件
    @Published var certP12: URL?
    @Published var certPass: String = ""
    @Published var profile: URL?
    @Published var teamId: String = ""
    /// iOS 18–26 需要 PC 生成的配对文件（pairing record）；iOS 27+ 可设备端自配对。
    @Published var pairingFile: URL?

    // 输入
    @Published var ipa: URL?
    @Published var dylib: URL?
    @Published var dylibName: String = "inject.dylib"

    // 状态
    @Published var status: String = "空闲"
    @Published var busy: Bool = false

    // 分阶段进度
    let stages = ["解压 IPA", "注入 dylib", "重签", "打包 IPA", "安装到设备"]
    @Published var stageIndex: Int = -1   // -1 表示空闲

    func run() {
        guard let ipa, let dylib else {
            status = "请先选择 IPA 和要注入的 dylib"
            return
        }
        busy = true
        status = "开始处理…"
        stageIndex = -1
        LogStore.shared.clear()

        // 文件来自「文件」App，属于安全作用域资源，必须先声明访问权，
        // 否则后台 Rust 读取会静默失败（这正是之前「点了没反应」的根因之一）。
        let candidates: [URL?] = [ipa, dylib, certP12, profile, pairingFile]
        var accessed: [(URL, Bool)] = candidates.compactMap { $0 }.map { ($0, $0.startAccessingSecurityScopedResource()) }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("si_\(UUID().uuidString)")
        let payload = tmp.appendingPathComponent("Payload")
        let outIpa = tmp.appendingPathComponent("signed.ipa")

        Task.detached { [weak self] in
            guard let self else { return }
            let r = RustBridge.shared

            self.setStage(0, "解压 IPA…")
            var code = r.unzip(ipa: ipa.path, out: payload.path)
            if code != 0 { self.finish("解压 IPA 失败"); self.stopAccess(&accessed); return }

            guard let app = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { self.finish("未在 Payload 中找到 .app"); self.stopAccess(&accessed); return }

            self.setStage(1, "注入 dylib…")
            code = r.inject(app: app.path, dylib: dylib.path, name: self.dylibName)
            if code != 0 { self.finish("注入 dylib 失败"); self.stopAccess(&accessed); return }

            self.setStage(2, "重签…")
            code = r.sign(app: app.path, p12: self.certP12?.path, pw: self.certPass,
                          prov: self.profile?.path, team: self.teamId)
            if code != 0 { self.finish("重签失败（检查证书/描述文件/Team ID）"); self.stopAccess(&accessed); return }

            self.setStage(3, "打包 IPA…")
            code = r.zip(dir: payload.path, out: outIpa.path)
            if code != 0 { self.finish("重新打包失败"); self.stopAccess(&accessed); return }

            // 安装：走本地回环隧道（参考 SideInstaller 的 LocalDevVPN 机制）
            self.setStage(4, "通过本地回环隧道安装…")
            let installResult = await InstallEngine.shared.install(
                ipaPath: outIpa.path,
                teamId: self.teamId,
                pairingURL: self.pairingFile
            )
            self.stopAccess(&accessed)
            self.finish(installResult.ok ? "已完成：已提交设备安装" : "安装未完成：\(installResult.message)")
        }
    }

    private func setStage(_ i: Int, _ msg: String) {
        DispatchQueue.main.async {
            self.stageIndex = i
            self.status = msg
        }
    }

    private func finish(_ msg: String) {
        DispatchQueue.main.async {
            self.status = msg
            self.busy = false
        }
    }

    private func stopAccess(_ accessed: inout [(URL, Bool)]) {
        for (url, ok) in accessed where ok {
            url.stopAccessingSecurityScopedResource()
        }
        accessed.removeAll()
    }
}
