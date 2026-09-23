# SideInjector

一个**跑在 iPhone 上**的 iOS App：在设备内部完成

```
导入证书 → 导入 IPA → 注入 dylib → 改 Bundle → 重签 → 打包 → 设备配对 → 安装到本机
```

即：**不需要电脑**，用你自己的开发证书给一颗 IPA 重签并装回同一台设备。

> 与桌面工具 `ipatool` 完全独立，本目录是单独项目，不要并入原工具。
> 仓库：https://github.com/gugegxy-jpg/SideInjector

---

## 快速开始（使用）

1. **装 SideInjector 本身**（必须侧载，不能上 App Store）。CI 产出的未签名 IPA 用 SideStore / AltStore / Sideloadly 等装上即可。
2. 打开 App → 首页 **证书** 区 → 「导入」选择你的 `.p12` + `.mobileprovision` + p12 密码（可保存多套，之后下拉直选）。
3. 首页 **输入** 区 → 「导入」选择要处理的 `.ipa`（导入即入库，之后可在下拉里重复选择）；需要注入的 `.dylib` 同样导入（可多选）。
4. 需要改 Bundle ID / 显示名时可填。
5. 点「**执行**」，依次走完 7 个阶段。
6. 之后可直接在「**库**」页签点击已签名的 IPA →「安装到设备」，无需重跑注入/签名。

**日志**：首页底部日志卡片有「复制」按钮，排障时把它发出来即可。

---

## 架构

```
SideInjector (SwiftUI)
   │  FFI（@_silgen_name，无 C 头文件）
   ▼
sideinjector-core (Rust, 编成 xcframework / staticlib)
   ├─ ziputil    解包 / 打包 IPA（保留符号链接）
   ├─ inject     主二进制插入 LC_LOAD_DYLIB（dylib 放 Frameworks/，constructor 自动执行）
   ├─ bundle     改 CFBundleIdentifier / CFBundleDisplayName
   ├─ sign       进程内 apple-codesign 0.27 重签（深签 → 浅签兜底）
   ├─ pair       设备端自配对（Remote Pairing，PairableHost + RpPairingFile）
   ├─ install    设备端安装（CoreDevice / RSD 链路）
   └─ logbridge  把 apple-codesign / apple-bundles 内部日志转发到 App 日志
```

**为什么签名不走外部二进制**：iOS 禁止 App `fork/exec` 子进程（`spawn` 报 `operation not permitted`），所以不能调用 `rcodesign` 命令行，只能把 `apple-codesign` 作为库链接进来，`default-features = false` 关掉公证相关重依赖。

---

## 功能状态

- [x] IPA 解包 / 打包（保留符号链接与权限位）
- [x] 主二进制注入 dylib，支持一次注入多个（注入名取各自文件名；重名自动加后缀）
- [x] 改 Bundle ID / 显示名
- [x] 进程内重签：`apple-codesign` 0.27，深签（递归重签所有嵌套 bundle）失败自动回退**浅签**（等价 `rcodesign --shallow`，嵌套代码保持原签名、只重签主 App）
- [x] 证书库：多套证书持久化、可编辑、覆盖安装后**路径按当前数据容器自愈**（不会丢）
- [x] 已签名 IPA 库：签名成功自动入库，点击即可再次安装
- [x] 导入即入库：IPA / dylib 落到 `Application Support/Inputs/`，不依赖文档选择器给的临时副本
- [x] 设备端自配对（Remote Pairing）：iOS 27+ 无需电脑；配对文件持久化，流程内只做一次
- [x] 设备端安装：CoreDevice / RSD 链路，带**真实进度**（installd 返回成功才算完成）
- [x] 流程控制：任一步失败即暂停并保留现场，「继续」从该步续跑；运行中可取消并清理临时文件
- [x] 环境自检卡片：iOS 版本与配对能力、loopback VPN 状态、隧道端口探测（62078 / 27015 / 49152）
- [ ] 注入 Fat / arm64e 主二进制（目前仅单切片 arm64）
- [ ] 安装链路的真机验证（刚完成实现，见下）

---

## 安装链路（重点）

iOS 17+ 的**设备端**安装只有一条路：**CoreDevice / RSD**。实测（App 内端口探测）：

| 端点 | 结果 |
|---|---|
| `127.0.0.1:62078`（经典 lockdownd） | 超时 |
| `127.0.0.1:27015`（usbmuxd） | 超时 |
| **`127.0.0.1:49152`（RSD）** | **可连接** |

因此经典 lockdownd 方案已废弃，改为：

```
TcpStream(127.0.0.1:49152)
  → RsdHandshake                     握手，拿到服务表（含各服务端口）
  → com.apple.afc                    上传 IPA 到 /PublicStaging
  → com.apple.mobile.installation_proxy   Install（ClientOptions.PackageType = Developer）
```

全部使用 [`idevice`](https://crates.io/crates/idevice)（MIT 许可）实现，**不涉及任何非商业许可代码**。进度由 installation_proxy 回传百分比，经 FFI 轮询上报 UI。

> 注意：安装是 **Developer 安装**，设备需已开启**开发者模式**（设置 → 隐私与安全性 → 开发者模式）。

---

## 构建

### 方式一：GitHub Actions（推荐，本机是 Windows 也能出包）

工作流 `.github/workflows/build-ipa.yml` 在 `macos-latest` 上构建：

1. `core/build_xcframework.sh` 编译 Rust core（`aarch64-apple-ios`）
2. `xcodegen generate` 生成工程
3. `xcodebuild archive` + 导出 / 打包 IPA
4. 上传 `SideInjector.ipa`（artifact）**并同时发布到 Release 的 `latest` 标签**

产物下载（推荐走 Release，走独立 CDN 且支持断点续传）：

```
https://github.com/gugegxy-jpg/SideInjector/releases/latest/download/SideInjector.ipa
```

多线程下载示例：

```bash
aria2c -x16 -s16 -k1M https://github.com/gugegxy-jpg/SideInjector/releases/latest/download/SideInjector.ipa
```

若配置了以下 Secrets，则走「签名导出」流程（否则产出未签名 IPA，用于侧载后自行签名）：

| Secret | 说明 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | 开发/分发证书 p12 的 base64 |
| `P12_PASSWORD` | p12 密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | mobileprovision 的 base64 |
| `TEAM_ID` | Apple Team ID（写入 `ExportOptions.plist`） |

### 方式二：本地 macOS

```bash
# 1. Rust iOS 目标 + 编译 core
rustup target add aarch64-apple-ios
cd core && ./build_xcframework.sh

# 2. 生成 Xcode 工程（签名由 core 进程内完成，无需任何外部工具）
brew install xcodegen
xcodegen generate
open SideInjector.xcodeproj
```

---

## 目录结构

```
core/                      Rust core（FFI 全部在 lib.rs）
  src/ziputil.rs           解/打包 IPA
  src/inject.rs            Mach-O 注入 LC_LOAD_DYLIB
  src/bundle.rs            改 Bundle ID / 显示名
  src/sign.rs              进程内 apple-codesign 签名 + 诊断
  src/install.rs           CoreDevice / RSD 安装链路
  src/pair.rs              设备端自配对
  src/logbridge.rs         库日志桥接
SideInjector/              SwiftUI App
  Model.swift              流程状态机（7 阶段 / 续跑 / 取消）
  ContentView.swift        首页（证书 / 输入 / 配对 / 环境自检 / 进度 / 日志）
  LibraryView.swift        库页签（证书库、已签名 IPA 库）
  CertStore.swift          证书库（路径按容器自愈）
  IPALibrary.swift         已签名 IPA 库（同上）
  InstallEngine.swift      安装调度 + 隧道端口探测 + 环境自检
  PairingController.swift  配对流程（Bonjour 广播 + PIN）
  RustBridge.swift         FFI 声明与封装
project.yml                XcodeGen 规格
.github/workflows/         CI
```

---

## 排障

| 现象 | 处理 |
|---|---|
| 点「执行」没反应 | 现在都会**弹窗**说明原因；首页日志里也有 `输入检查：…` 行指出是哪个文件不可用 |
| 覆盖安装后证书「丢了」 | 已在「库」页签点该证书的「编辑」，重选 P12 与描述文件保存即可（本版已做路径自愈，正常情况下会自动找回） |
| 安装失败 | 先看**环境自检**卡片：确认 49152 可连接、开发者模式已开；再看日志里的 `install error: …` |
| 签名报 `I/O error: No such file or directory (os error 2)` | 这个错误**不带路径**。请复制日志里这几类行：`bundle 诊断：顶层文件 …`、`bundle 诊断：主 bundle / 嵌套 …`、`签名中断：输出目录已产出文件 …`、`签名中断：最后写入 …`、以及报错前的 `[apple_…]` 行 |
| App 启动崩溃（注入后） | 被注入的 dylib 必须与宿主 App 用**同一张证书**重签；宿主需带 `get-task-allow` 等 entitlement |

---

## 已知问题 / 限制

1. **签名可能在个别嵌套 bundle 上中断**：`apple-codesign` 0.27 遍历某个 framework 之后、写 `_CodeSignature/CodeResources` 之前抛 ENOENT（错误不带路径）。当前已内置：库日志桥接、镜像其 bundle 判定规则的结构诊断、签名中断点报告，以及**浅签兜底**（浅签模式下嵌套代码整体原样复制，只重签主 App）。
2. **安装链路刚实现**，等待真机验证；失败时日志会给出 RSD 服务清单与完整错误链。
3. `InstallEngine` 里旧的经典 lockdownd / usbmux 实现已是**死代码**，待清理。
4. 注入仅支持单切片 arm64 主二进制；Fat / arm64e 未实现。
5. 仅对普通第三方 IPA 有效；系统 App 注入无 jailbreak 不可行。
6. 本工具自身必须侧载，并需放宽沙盒 entitlement（见 `SideInjector.entitlements`）。

---

## 代码出处与致谢

本项目**参考/借鉴了以下开源项目**，特此注明出处。若你是相关作者、认为署名方式不妥，请开 Issue，我会立即更正。

### 1. FrizzleM/SideInstaller —— 参考实现（自有许可）

<https://github.com/FrizzleM/SideInstaller>

设备端配对 / 安装的**整体思路、模块划分与 UI 风格**参考自该项目。对应关系：

| 本仓库 | 参考其 | 借鉴程度 |
|---|---|---|
| `core/src/pair.rs` | `rust-core/src/pairing.rs` | 配对流程组织、机型标识处理（协议实现来自 `idevice`） |
| `SideInjector/PairingController.swift` | `PairingController` / `PairingManager` | Bonjour 广播、PIN、状态轮询的组织方式 |
| `SideInjector/InstallEngine.swift` | 安装端点候选与回环探测策略 | 候选地址枚举、错误提示用语 |
| `SideInjector/Theme.swift` | `Theme.swift` | 配色、卡片风格（风格参照，非逐行复制） |
| `SideInjector/ContentView.swift` | 首页 UI / 交互 | 全宽自适应、四态步骤图标、按钮内显示当前阶段、仅安装时显示进度条 |

**必须遵守的许可条款**（*SideInstaller License*，Copyright © 2026 FrizzleM；属自定义许可，非标准开源协议）：

- 允许使用、复制、修改，并**允许以源码形式再分发**——须附带该许可证与版权声明，且**标明所做修改**；
- **禁止商业使用**（Commercial Use 需另行书面授权）；
- **禁止再分发其官方构建 / IPA**（重新打包、重签名、镜像等均不允许）；
- **必须署名**：须标注 “**SideInstaller by FrizzleM**” 并链接官方仓库（本条已由本 README 满足）。

> 因此：上表所列**参考其写成的部分不适用 MIT**，并受“禁止商业使用”约束。若需商用，请先联系 FrizzleM 取得授权，或把这些部分替换为独立实现（`core/src/pair.rs` 与安装链路已建立在 MIT 许可的 `idevice` crate 之上，替换成本可控）。

### 2. indygreg/apple-platform-rs —— `apple-codesign`（MPL-2.0，库依赖）

<https://github.com/indygreg/apple-platform-rs>

- `core/src/sign.rs` 以**库形式**链接 `apple-codesign`（0.27，`default-features = false`）完成重签。之所以不调用 `rcodesign` 命令行：iOS 禁止 App `fork/exec` 子进程；
- `core/src/sign.rs` 里的**签名前结构诊断**，是阅读同仓库 `apple-bundles` 的 `DirectoryBundle` 实现后，按其 bundle 判定规则（是否 `shallow`、优先 `Resources/Info.plist`、嵌套 bundle 候选）写成的镜像检查；
- `core/src/logbridge.rs` 把其 `log` 输出桥接到 App 日志，用于定位它**不带路径**的 IO 错误。

MPL-2.0 为**文件级弱著佐权**：本项目未修改其源码（仅作依赖使用），保留其许可证与出处声明即可，自有源码不受其传染。

### 3. jkcoxson/idevice（MIT，库依赖）

<https://github.com/jkcoxson/idevice>（作者 Jackson Coxson）

- `core/src/install.rs`：RSD 握手（`RsdHandshake`）、AFC 上传、`installation_proxy` 安装（`PackageType = Developer`）；
- `core/src/pair.rs`：`remote_pairing::PairableHost` / `RpPairingFile` 等设备自配对协议实现。

### 4. 其他依赖

| crate | 许可 | 用途 |
|---|---|---|
| `zip` / `plist` / `log` / `tokio` / `serde_json` / `anyhow` | MIT / Apache-2.0 | 打包、plist、日志、异步、序列化 |

### 5. 仅作为外部工具使用（未引入其代码）

- **SideStore / AltStore**：用于把 SideInjector 本身侧载进设备；
- **StosVPN / SideStore 的 loopback VPN 描述文件**：为设备端安装提供到本机 RSD 的回环通道。

---

## 许可证

- **本仓库自有代码**：MIT；
- **参考 SideInstaller 写成的部分**（见上表）：适用 *SideInstaller License* —— 允许以源码形式使用 / 修改 / 分发并须署名，**禁止商业使用**；
- **第三方依赖**：`apple-codesign`（MPL-2.0）、`idevice`（MIT）、`zip` / `plist` / `log` / `tokio` / `serde_json` / `anyhow`（MIT 或 Apache-2.0）。

署名声明：

> 本项目包含参考 **SideInstaller by FrizzleM**（<https://github.com/FrizzleM/SideInstaller>）写成的实现。该部分按其 *SideInstaller License*（Copyright © 2026 FrizzleM）发布，**禁止商业使用**，且不得再分发其官方构建 / IPA。
