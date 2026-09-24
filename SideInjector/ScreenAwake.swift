import UIKit

/// 执行期间不让设备息屏。
///
/// 为什么需要：整个流程（解包 → 注入 → 签名 → 打包 → 上传安装）可能持续几分钟到十几分钟，
/// 中途自动息屏会让 App 被挂起、流程断在半路（尤其上传 / 安装阶段）。
///
/// 用系统标准的 `UIApplication.isIdleTimerDisabled`：不需要任何权限、不改变锁屏策略、
/// 也不会阻止用户**手动**锁屏（手动锁屏时系统照样锁屏 —— 那种情况需要后台音频保活，
/// 见 `KeepAlive.swift`；两者机制不同，互不冲突）。
///
/// 由 `Model.outcome` 驱动：执行中 / 等待继续（`.running` / `.paused`）= 开启，
/// 完成 / 失败 / 取消 / 空闲（`.done` / `.idle`…）= 关闭。挂在状态上而不是散在流程各处调用，
/// 任何一条退出路径都会自动恢复，不会出现「流程结束了屏幕还亮着」。
enum ScreenAwake {
    /// 打开 / 恢复息屏（可从任意线程调用 —— UIKit 状态只能在主线程改，内部会切过去）。
    static func set(_ on: Bool) {
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = on
        } else {
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = on }
        }
    }
}
