import SwiftUI

@main
struct SideInjectorApp: App {
    init() {
        _ = RustBridge.shared // 注册日志回调
        // 让 Rust 签名后端指向 App 内置的 rcodesign(iOS) 二进制
        if let rc = Bundle.main.url(forResource: "rcodesign", withExtension: nil)?.path {
            setenv("RCODESIGN_PATH", rc, 1)
            LogStore.shared.append("已加载内置 rcodesign：\(rc)")
        } else {
            LogStore.shared.append("未找到内置 rcodesign，App 内重签将不可用")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Model.shared)
                .environmentObject(LogStore.shared)
        }
    }
}
