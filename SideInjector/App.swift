import SwiftUI

@main
struct SideInjectorApp: App {
    init() {
        _ = RustBridge.shared // 注册日志回调
        // 让 Rust 签名后端指向 App 内置的 rcodesign(iOS) 二进制
        if let rc = locateRcodesign() {
            // 确保可执行（部分 sideload/重签流程会清掉 +x）
            if !FileManager.default.isExecutableFile(atPath: rc) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                        ofItemAtPath: rc)
            }
            setenv("RCODESIGN_PATH", rc, 1)
            LogStore.shared.append("已加载内置 rcodesign：\(rc)")
        } else {
            LogStore.shared.append("未找到内置 rcodesign，App 内重签将不可用（请安装含 rcodesign 的最新 IPA）")
        }
    }

    /// 在 App 包内定位 rcodesign 二进制（无扩展名）。
    private func locateRcodesign() -> String? {
        if let u = Bundle.main.url(forResource: "rcodesign", withExtension: nil) {
            return u.path
        }
        // 兜底：直接在 App 包根目录按文件名查找
        let root = Bundle.main.bundleURL
        let cand = root.appendingPathComponent("rcodesign")
        return FileManager.default.fileExists(atPath: cand.path) ? cand.path : nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Model.shared)
                .environmentObject(LogStore.shared)
        }
    }
}
