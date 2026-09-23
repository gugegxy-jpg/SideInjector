# SideInjector

一个 **跑在 iPhone 上的 iOS App**，在设备内完成：导入开发证书 → 注入 dylib → 用导入的证书重签 → 打包 → 走设备端回环（CoreDevice / SideInstaller 式）安装到同一台设备。

> 与桌面工具 `ipatool` 完全独立，本目录是单独项目，不要并入原工具。

## 架构

```
SideInjector (SwiftUI)
   │  FFI (@_silgen_name)
   ▼
sideinjector-core (Rust, 编成 xcframework)
   ├─ ziputil  解/打包 IPA
   ├─ inject   Mach-O 插入 LC_LOAD_DYLIB（constructor 自动执行）
   ├─ sign     用导入的证书重签（进程内链接 apple-codesign 库，不走子进程）
   └─ install  设备端安装 ◀── 需接入 SideInstaller rust-core（见下）
```

## 已实现

- ✅ IPA 解包 / 打包（zip）
- ✅ 主二进制注入 dylib（单切片 arm64 Mach-O；Fat/arm64e 为 TODO）
- ✅ 证书导入 UI + 用 p12 + mobileprovision 重签（进程内 apple-codesign 库签名；深签失败自动回退浅签）
- ⬜ 设备端安装传输（CoreDevice 本机回环）

## 未实现 / 关键风险

1. **安装传输**：iOS 17+ 的应用安装走私有 CoreDevice / lockdownd 协议，已在 `core/src/install.rs`
   标为集成点。需把 [SideInstaller](https://github.com/FrizzleM/SideInstaller) 的 `rust-core`
   （remote / core_device / lockdown / dvt 模块）并入本 crate 并调用其安装例程。
   - iOS 27：可完全设备端自配对。
   - iOS 18–26：仍需 PC 先生成一个 pairing file。
   - **许可证**：SideInstaller 源码非商业可用、禁止再分发官方构建，商用请自行评估。
2. **库校验**：被注入的 dylib 必须用同一张证书重签；宿主 App 需带 `get-task-allow` 等 entitlement，
   否则启动崩溃。普通第三方 IPA 可行；系统 App 注入无 jailbreak 不可行。
3. **工具 App 自身**：必须侧载（不能上 App Store），且需放宽沙盒 entitlement（见 `SideInjector.entitlements`）。
   用你自己的开发证书给本工具签名即可形成闭环。

## 构建（需在 macOS 上）

```bash
# 1. Rust iOS 目标 + 编 xcframework
rustup target add aarch64-apple-ios
cd core && ./build_xcframework.sh

# 2. 生成 Xcode 工程并运行（签名由 core 进程内完成，无需再准备任何外部工具）
brew install xcodegen
xcodegen generate
open SideInjector.xcodeproj
```

> 本仓库在 Windows 环境下创建，仅做源码脚手架；Rust/iOS 编译与真机验证必须在 macOS + Xcode 完成。

## 许可证

代码以 MIT 提供；接入 SideInstaller `rust-core` 时须遵守其许可证。
