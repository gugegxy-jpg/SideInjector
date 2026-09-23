import SwiftUI

@main
struct SideInjectorApp: App {
    init() {
        _ = RustBridge.shared // 注册日志回调
        // 注：不再需要内置 rcodesign —— iOS 禁止 fork/exec 子进程，无法调用它；
        // 签名由 core 进程内链接 apple-codesign 库完成（见 core/src/sign.rs）。
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Model.shared)
                .environmentObject(LogStore.shared)
        }
    }
}
