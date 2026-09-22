import SwiftUI
import Combine

final class Model: ObservableObject {
    static let shared = Model()

    // 证书 / 描述文件
    @Published var certP12: URL?
    @Published var certPass: String = ""
    @Published var profile: URL?
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

    // 安装环境检测（本地回环隧道是否「绿」）
    @Published var tunnelStatus: TunnelStatus? = nil

    /// 已签名 IPA 的本地路径；生成后可分享/保存到「文件」App 手动安装。
    @Published var shareItem: URL? = nil

    func checkEnvironment() {
        tunnelStatus = nil
        Task.detached { [weak self] in
            guard let self else { return }
            let s = await InstallEngine.shared.diagnose()
            DispatchQueue.main.async { self.tunnelStatus = s }
        }
    }

    func run() {
        guard let ipa else {
            status = "请先选择 IPA 文件"
            return
        }
        busy = true
        status = "开始处理…"
        stageIndex = -1
        shareItem = nil
        LogStore.shared.clear()

        // 文件来自「文件」App，属于安全作用域资源，必须先声明访问权，
        // 否则后台 Rust 读取会静默失败（这正是之前「点了没反应」的根因之一）。
        let candidates: [URL?] = [ipa, dylib, certP12, profile, pairingFile]
        var accessed: [(URL, Bool)] = candidates.compactMap { $0 }.map { ($0, $0.startAccessingSecurityScopedResource()) }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("si_\(UUID().uuidString)")
        // signed.ipa 放在 tmp 之外，避免被一起打包回 IPA
        let outIpa = fm.temporaryDirectory.appendingPathComponent("signed_\(UUID().uuidString).ipa")

        // 在主线程先读一次隧道状态，避免在后台任务里访问 @Published 造成数据竞争
        let installViaTunnel = self.tunnelStatus?.ok == true

        Task.detached { [weak self] in
            guard let self else { return }
            let r = RustBridge.shared

            // 解压到 tmp（保留 zip 内的 Payload/ 前缀，避免变成 Payload/Payload/App.app）
            self.setStage(0, "解压 IPA…")
            var code = r.unzip(ipa: ipa.path, out: tmp.path)
            if code != 0 { self.finish("解压 IPA 失败"); self.stopAccess(&accessed); return }

            // 规范化：确保存在 tmp/Payload（个别 IPA 没有 Payload 目录则把 .app 移进去）
            var payload = tmp.appendingPathComponent("Payload")
            if !fm.fileExists(atPath: payload.path) {
                if let app = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }) {
                    try? fm.createDirectory(at: payload, withIntermediateDirectories: true)
                    try? fm.moveItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
                }
            }

            guard let app = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { self.finish("未在 Payload 中找到 .app"); self.stopAccess(&accessed); return }

            // 注入 dylib 为可选项：未选择则跳过，直接进入签名 + 安装
            if let dylib = self.dylib {
                self.setStage(1, "注入 dylib…")
                code = r.inject(app: app.path, dylib: dylib.path, name: self.dylibName)
                if code != 0 { self.finish("注入 dylib 失败"); self.stopAccess(&accessed); return }
            } else {
                self.setStage(1, "未选择 dylib，跳过注入")
                LogStore.shared.append("run: 未选择 dylib，直接进入签名")
            }

            self.setStage(2, "重签…")
            code = r.sign(app: app.path, p12: self.certP12?.path, pw: self.certPass,
                          prov: self.profile?.path, team: "")
            if code != 0 { self.finish("重签失败（检查证书/描述文件/Team ID）"); self.stopAccess(&accessed); return }

            self.setStage(3, "打包 IPA…")
            // 打包整个 tmp（自动带 Payload/ 前缀，生成合法 IPA）
            code = r.zip(dir: tmp.path, out: outIpa.path)
            if code != 0 { self.finish("重新打包失败"); self.stopAccess(&accessed); return }

            // 已生成可安装的已签名 IPA（无论是否走自动安装都先暴露给用户）
            DispatchQueue.main.async { self.shareItem = outIpa }

            // 安装：优先走本地回环隧道（参考 SideInstaller 的 LocalDevVPN 机制）；
            // 隧道不可用时（无配对 Mac / 未装 LocalDevVPN）不致命，改为提示手动安装。
            if installViaTunnel {
                self.setStage(4, "通过本地回环隧道安装…")
                let installResult = await InstallEngine.shared.install(
                    ipaPath: outIpa.path,
                    pairingURL: self.pairingFile
                )
                self.stopAccess(&accessed)
                self.finish(installResult.ok ? "已完成：已提交设备安装" : "安装未完成：\(installResult.message)")
            } else {
                self.stopAccess(&accessed)
                self.finish("已生成已签名 IPA：本机回环隧道不可用，请点「分享已签名 IPA」用 AltStore/SideStore 安装")
            }
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
