import SwiftUI

@main
struct SideInjectorApp: App {
    init() {
        _ = RustBridge.shared // 注册日志回调
        // 注：不再需要内置 rcodesign —— iOS 禁止 fork/exec 子进程，无法调用它；
        // 签名由 core 进程内链接 apple-codesign 库完成（见 core/src/sign.rs）。
        // apple-codesign 出处：https://github.com/indygreg/apple-platform-rs （MPL-2.0）。

        // 自动清理解包残留：流程被系统杀掉时（大包很容易触发），tmp 里会留下
        // `si_out_*` 解包工作树、`si_in_*` 输入副本、`si_export_*` 导出产物等，动辄几个 GB。
        // 启动时全清；放后台队列是避免几十 GB 的删除拖慢启动。
        DispatchQueue.global(qos: .utility).async {
            let freed = Storage.cleanWorkDirs()
            if freed > 50 * 1024 * 1024 {
                LogStore.shared.append("已自动清理上次运行残留 \(Storage.human(freed))")
            }
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
