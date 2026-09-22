//! 设备端安装 —— 本项目的「硬骨头」。
//!
//! 要让一个 iOS App 把另一个 IPA 装到同一台设备，必须走 Apple 在 iOS 17+ 引入的
//! CoreDevice / lockdownd 本机回环协议（即 SideInstaller 的 `rust-core` 所逆向实现的部分）。
//! 这部分是私有协议，无法凭空重写，因此这里只给出 FFI 边界与接入指引。
//!
//! 接入方式（推荐）：
//!   1. 把 SideInstaller 仓库的 `rust-core`（remote / core_device / lockdown / dvt 模块）
//!      作为子模块/源码并入本 crate（注意其许可证：非商业可用、禁止再分发官方构建）。
//!   2. 在此函数内调用其安装例程，例如：
//!        core_device::install_ipa(ipa)
//!      或在已建立 tunnel 后调用 DVTInstallApplication 路径。
//!
//! iOS 版本约束：iOS 27 可完全设备端自配对；iOS 18–26 仍需 PC 先生成一个 pairing file。

use crate::log_msg;
use anyhow::{bail, Result};
use std::path::Path;

pub fn install_ipa(ipa: &Path) -> Result<()> {
    log_msg("install: CoreDevice 设备端传输层尚未接入");
    log_msg("-> 请将 SideInstaller 的 rust-core（CoreDevice/lockdown）并入本 crate 后调用其安装路径");
    log_msg(&format!("   目标 IPA: {}", ipa.display()));
    bail!("设备端安装传输未实现：需接入 SideInstaller rust-core 的 CoreDevice 栈")
}
