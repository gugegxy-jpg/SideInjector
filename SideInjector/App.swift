import SwiftUI

@main
struct SideInjectorApp: App {
    init() {
        _ = RustBridge.shared // 注册日志回调
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(Model.shared)
                .environmentObject(LogStore.shared)
        }
    }
}
