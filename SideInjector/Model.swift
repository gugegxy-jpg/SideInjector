import SwiftUI
import Combine

final class Model: ObservableObject {
    static let shared = Model()

    // 证书 / 描述文件
    @Published var certP12: URL?
    @Published var certPass: String = ""
    @Published var profile: URL?
    @Published var teamId: String = ""

    // 输入
    @Published var ipa: URL?
    @Published var dylib: URL?
    @Published var dylibName: String = "inject.dylib"

    // 状态
    @Published var status: String = "空闲"
    @Published var busy: Bool = false

    func run() {
        guard let ipa, let dylib else {
            status = "请先选择 IPA 和要注入的 dylib"
            return
        }
        busy = true
        status = "开始处理…"
        LogStore.shared.clear()

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("si_\(UUID().uuidString)")
        let payload = tmp.appendingPathComponent("Payload")
        let outIpa = tmp.appendingPathComponent("signed.ipa")

        Task.detached { [weak self] in
            guard let self else { return }
            let r = RustBridge.shared

            var code = r.unzip(ipa: ipa.path, out: payload.path)
            if code != 0 { self.finish("解压 IPA 失败"); return }

            guard let app = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { self.finish("未在 Payload 中找到 .app"); return }

            code = r.inject(app: app.path, dylib: dylib.path, name: self.dylibName)
            if code != 0 { self.finish("注入 dylib 失败"); return }

            code = r.sign(app: app.path, p12: self.certP12?.path, pw: self.certPass,
                          prov: self.profile?.path, team: self.teamId)
            if code != 0 { self.finish("重签失败（检查证书/描述文件）"); return }

            code = r.zip(dir: payload.path, out: outIpa.path)
            if code != 0 { self.finish("重新打包失败"); return }

            code = r.install(ipa: outIpa.path)
            self.finish(code == 0 ? "已提交安装" : "安装失败：设备端传输层未接入（见 install.rs）")
        }
    }

    private func finish(_ msg: String) {
        DispatchQueue.main.async {
            self.status = msg
            self.busy = false
        }
    }
}
