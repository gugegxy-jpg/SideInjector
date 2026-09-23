# 第三方代码声明（Third-Party Notices）

本仓库包含**参考/借鉴其他开源项目**写成的实现，以及若干运行时依赖。按各自许可的要求，
在此集中声明出处、许可与改动；各源码文件头部也标注了对应出处的简版说明。

> **若你要再分发本仓库（源码或构建产物），请连同本文件与上游许可证全文一并分发。**

---

## 1. SideInstaller —— 参考实现（自定义许可，禁止商业使用）

- 项目：**FrizzleM/SideInstaller** — <https://github.com/FrizzleM/SideInstaller>
- 许可证：**SideInstaller License**（自定义许可，非 OSI 标准协议）
- 版权：Copyright © 2026 FrizzleM
- 许可证文件：上游仓库根目录的 `LICENSE.md`（2918 字节）
  - 原文地址：<https://raw.githubusercontent.com/FrizzleM/SideInstaller/main/LICENSE.md>
- 关键条款（概括，**一切以原文为准**）：
  1. **允许**：为个人、教育、非商业目的使用 / 运行 / 研究 / 复制 / 修改本软件；允许
     **以源码形式**再分发本软件或衍生作品，前提是**附带本许可证与版权声明**，并
     **清楚标明所做修改**。
  2. **禁止**：任何**商业使用 / 变现**（销售、基于它的安装服务收费、捆绑进付费产品、
     以广告 / 订阅 / 捐赠变现等），除非取得版权持有人的书面授权。
  3. **禁止**：**再分发其官方发布版本**（"Official Releases"，即版权方发布的编译产物 /
     IPA 等，包括重新托管、镜像、重新打包、重新签名），无论是否修改。
  4. **必须署名**：使用本软件的项目须在其文档或「关于」页标注
     **"SideInstaller by FrizzleM"** 并链接官方仓库。
  5. 违反即自动终止授权；授权是否恢复由版权持有人决定。

- 本仓库中参考它写成的部分：

| 本仓库文件 | 参考其 | 改动说明 |
|---|---|---|
| `core/src/pair.rs` | `rust-core/src/pairing.rs` | 配对流程组织与机型标识处理；协议实现改用 MIT 许可的 `idevice` crate；状态上报改为「后台线程 + 全局状态 + Swift 轮询」模型 |
| `SideInjector/PairingController.swift` | `PairingController` / `PairingManager` | 状态一律取自 Rust 侧轮询；新增 Network 权限探测与配对文件持久化 |
| `SideInjector/InstallEngine.swift` | 安装端点候选与回环探测策略 | 只保留候选枚举、超时控制与错误提示；实际安装走本项目 Rust core（`idevice`） |
| `SideInjector/Theme.swift` | `Theme.swift` | 视觉风格参照，按本 App 需要重新编写 |
| `SideInjector/ContentView.swift` | 首页 UI / 交互 | 布局与交互风格对齐（全宽自适应、四态步骤图标、按钮内显示当前阶段、仅安装时显示进度条） |

- 署名（依其许可要求）：

> 本项目包含参考 **SideInstaller by FrizzleM**（<https://github.com/FrizzleM/SideInstaller>）
> 写成的实现。该部分按其 *SideInstaller License*（Copyright © 2026 FrizzleM）发布，
> **禁止商业使用**，且不得再分发其官方构建 / IPA。

- 声明：本仓库**未再分发** SideInstaller 的任何官方构建、IPA 或二进制，仅在其许可允许的
  范围内参考其源码实现。若需商业使用，请先向其作者取得授权，或替换上表所列部分
  （`core/src/pair.rs` 与安装链路已建立在 MIT 许可的 `idevice` 之上，替换成本可控）。

---

## 2. apple-platform-rs —— apple-codesign / apple-bundles（MPL-2.0，库依赖）

- 项目：**indygreg/apple-platform-rs** — <https://github.com/indygreg/apple-platform-rs>
- 许可：**MPL-2.0**（Mozilla Public License 2.0，文件级弱著佐权）
- 使用方式：以**库依赖**形式（`apple-codesign = "0.27"`，`default-features = false`）
  链接进 Rust core 完成进程内签名。**本仓库未修改其源码**（未 vendor、未打补丁）。
- 涉及文件：
  - `core/src/sign.rs`：库签名调用链。其中 `diagnose_bundle` / `classify_bundle` /
    `report_bundle` 等函数，是阅读 `apple-bundles` 的 `DirectoryBundle` 实现后写成的
    **镜像检查**（复现其 bundle 判定规则：`shallow`、优先 `Resources/Info.plist`、
    嵌套 bundle 候选），用于定位该库抛出的、**不带路径**的 IO 错误（ENOENT）。
  - `core/src/logbridge.rs`：把该库内部的 `log` 输出转发到 App 日志（本项目自有实现）。
- 义务：保留其许可与出处声明；分发二进制时提供获取其源码的途径
  （crates.io: <https://crates.io/crates/apple-codesign>，上游仓库同上）。
  MPL-2.0 为文件级弱著佐权，本仓库自有源码不受其传染。

---

## 3. idevice（MIT，库依赖）

- 项目：**jkcoxson/idevice** — <https://github.com/jkcoxson/idevice>（作者 Jackson Coxson）
- 许可：**MIT**
- 使用方式：`idevice = "0.1.63"`（features：`remote_pairing` / `tcp` / `ring` / `rsd` /
  `afc` / `installation_proxy`），提供设备自配对（Remote Pairing）与设备端安装
  （RSD 握手、AFC 上传、installation_proxy）的协议实现。
- 涉及文件：`core/src/install.rs`、`core/src/pair.rs`
- 义务：保留其版权声明与许可声明（本文件即其中一处）。

---

## 4. 其他依赖（Cargo / Swift 生态）

| 依赖 | 许可 | 用途 |
|---|---|---|
| `zip` | MIT | IPA 解包 / 打包 |
| `plist` | MIT / Apache-2.0 | Info.plist、配对文件解析 |
| `log` | MIT / Apache-2.0 | 日志桥接 |
| `tokio` | MIT | 异步运行时（TCP / RSD 链路） |
| `serde_json` | MIT / Apache-2.0 | JSON 序列化 |
| `anyhow` | MIT / Apache-2.0 | 错误处理 |
| Apple 系统框架（SwiftUI / Network / Security / UIKit） | Apple SDK 条款 | App 界面与网络 |

---

## 5. 仅作为外部工具使用（未引入其代码）

- **SideStore / AltStore**：用于把本 App 侧载到设备。
- **StosVPN / SideStore 的 loopback VPN 描述文件**：为设备端安装提供到本机 RSD 的回环通道。

---

## 6. 本仓库自身

除上面列出的参考部分与第三方依赖外，其余代码为本项目自有实现，以 **MIT** 提供。
由于包含参考 SideInstaller 写成的部分（见第 1 节），**整体不可用于商业用途**。
