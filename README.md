# SideInjector

一个**运行在 iPhone 上**的 iOS 应用，全部处理均在设备内部完成：

```
导入证书 → 导入 IPA → 注入 dylib → 改 Bundle → 重签 → 打包 → 设备配对 → 安装到本机
```

即：**无需电脑**，使用开发者自己的证书为 IPA 重新签名，并安装回同一台设备。


**支持的系统：iOS 17.0 及以上。** 本工具**自身**必须运行在 iOS 17 及以上：设备端安装走的是
iOS 17 才引入的 **CoreDevice / RSD（49152）** 链路。

---

## 快速开始（使用）

1. **安装 SideInjector 本身**（必须侧载）。CI 产出的未签名 IPA 可用 SideStore / AltStore / Sideloadly 等安装。
2. 打开 App → 首页 **证书** 区 → 「导入」选择 `.p12` + `.mobileprovision` 与 p12 密码（可保存多套，之后从下拉列表直接选择）。
3. 首页 **输入** 区 → 「导入」选择待处理的 `.ipa`（导入后即入库，之后可在下拉列表中重复选择）；需要注入的 `.dylib` 同样导入（支持多选）。
4. 如需修改 Bundle ID / 显示名，在该处填写。
5. 点击「**执行**」，依次完成 7 个阶段。
   - **仅注入、不签名**：在证书区勾选「跳过签名（只注入后导出）」，流程执行到「打包 IPA」即结束，
     产出未签名 IPA，再用「导出 / 分享」保存到「文件」App（该模式不会触发设备配对与安装）。
6. 之后可直接在「**库**」页签点击已签名的 IPA →「安装」，无需重新执行注入与签名；
   「**库**」页签还支持「**导入已签名 IPA**」：导入其它来源已签名的包，同样可以一键安装或再次导出。

**日志**：首页底部日志卡片提供「复制」按钮，排障时将其内容发出即可。

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
   ├─ sign       进程内 apple-codesign 0.27 重签（嵌套项只重签主可执行 + 主 App 浅签）
   ├─ pair       设备端自配对（Remote Pairing，PairableHost + RpPairingFile）
   ├─ install    设备端安装（CoreDevice / RSD 链路）
   └─ logbridge  把 apple-codesign / apple-bundles 内部日志转发到 App 日志
```

**签名不使用外部二进制的原因**：iOS 禁止 App `fork/exec` 子进程（`spawn` 报 `operation not permitted`），
因此无法调用 `rcodesign` 命令行，只能将 `apple-codesign` 以库的形式链接进来，并以
`default-features = false` 关闭公证相关重依赖。

---

## 功能状态

- [x] IPA 解包 / 打包（保留符号链接与权限位）
- [x] 主二进制注入 dylib，支持一次注入多个（注入名取各自文件名；重名自动加后缀）
- [x] 改 Bundle ID / 显示名：导入 IPA 后将「当前值」作为**提示**显示（**不预填输入框**，留空仍表示不修改），
      且**仅在值确实发生变化时才写入 `Info.plist`**；嵌套扩展的 Bundle ID 只在主 ID 变化时连带同步，
      另配**显式开关**「同步嵌套扩展 Bundle ID」，用于修复第三方改包自带的错配
      （扩展 ID 属于运行时身份，不做自动改写）
- [x] 进程内重签：`apple-codesign` 0.27。嵌套项（framework / appex）**逐个只重签主可执行文件**，
      并将签名标识强制设为该 bundle 的 `CFBundleIdentifier`（否则 installd 报
      `MismatchedBundleIDSigningIdentifier`）；资源 bundle 仍按 bundle 级签名（仅封资源）；
      最后**浅签主 App**，将全部内容封入主 App 的 `CodeResources`
- [x] **浅签阶段会覆盖嵌套签名**，已针对性处理：`apple-codesign` 的「浅签」并非仅复制嵌套代码，
      而会将 app 内所有嵌套 Mach-O 逐个重签（`signing Mach-O file Frameworks/xxx.framework/xxx`），
      且该路径**不继承 `Main` 作用域标识**，标识会按二进制名重新计算。现为每个嵌套 Mach-O 登记
      **路径作用域标识**（`SettingsScope::Path("Frameworks/xxx.framework/xxx")`），浅签时使用该值
- [x] **签名标识自检**：签名完成后自行解析新签名的 `CodeDirectory`，将标识读回逐项比对，
      并在**最终会打进 IPA 的那份 app** 上汇总（`签名标识自检：检查 N 项，不匹配 M 项`，为 0 才算全部正确）
- [x] **日志分两级，且不影响界面流畅度**：**重要日志**（阶段、汇总、自检、错误）显示在首页日志卡片；
      **细节日志**（逐项进度、apple-codesign / goblin / idevice 内部输出、RSD 服务清单等诊断信息）
      只写入后台日志文件 `Application Support/Logs/sideinjector.log`。Rust 侧过滤 `goblin` /
      `apple_codesign::code_resources` 的逐条输出；Swift 侧**每 0.2 秒合并提交一次**、
      日志卡片独立观察 `LogStore`、界面仅渲染末尾 200 行
- [x] **日志管理**：首页日志卡片可「复制」完整日志（含细节日志的文件快照，直接写入剪贴板，并提示行数与大小）、
      「导出」（分享 / 存储到「文件」）、「清空」（内存与文件同时清理；超过 4 MB 自动轮转，保留一份
      `sideinjector.1.log`）。说明：**不提供「查看全部」** —— 数千行文本一次性交给 `Text` 排版无法渲染；
      该入口的实际用途仅为「取出日志」，因此直接实现为复制
- [x] **顶部状态实时显示**：标题栏展示 `iOS 版本`、`LocalDevVPN`、`WiFi` 三项状态胶囊，
      使用 `NWPathMonitor` 实时刷新，开关 WiFi / 连接或断开 VPN 均会立即反映；判据与「环境自检」一致：
      **LocalDevVPN 依据「隧道上带 10.7.x.x 地址」判定**，而非「存在 utun/ipsec/ppp 隧道接口」——
      后者会将 Shadowrocket 一类普通 VPN 误判为 LocalDevVPN 已连接。
      说明：**安装链路不访问外网** —— 全程为本机内的 loopback VPN 隧道 → RSD → AFC /
      installation_proxy → installd，WiFi 本身不提供通路（连接自己的 LAN 地址仍走本机回环，沙盒限制相同）；
      安装开始时也会记录一行 `install: 网络环境：WiFi … · LocalDevVPN …`，便于事后对照
- [x] **状态栏蒙版**：内容（标题、卡片）滚动到系统状态栏下面时，时钟与电量不再与 App 文字重叠。
      **常驻显示，但正常情况下不可见**：仅模糊、不叠色 —— 使用 UIKit 纯模糊
      `UIBlurEffect(style: .regular)`（`BlurOnly` + `UIViewRepresentable`），
      对平滑渐变背景做模糊的结果与背景本身基本一致，因此无内容经过时不可见；
      内容滚动到其下时立即呈现毛玻璃效果。**有意不使用** `.ultraThinMaterial` / `.glassEffect`：
      二者在模糊之外还会叠加一层填充色（Liquid Glass 另带高光），在深色渐变背景上会呈现可见的条带。
      **强度亦非全条一致**：模糊会轻微降饱和，等强度时边界仍可见，因此强度做成自上而下的渐变 ——
      顶端约 0.75（可见模糊，但不至于是实心色块），向下递减至 0，与背景完全融合；
      如需调整，只需修改 `StatusBarMask` 中 mask 的若干 opacity。高度为 `safeAreaInsets.top + 14`，
      整层 `allowsHitTesting(false)`（不响应点击），两个页签均受保护。
      曾评估后放弃的两条方案：① 「iOS 26+ 交由系统的 scroll edge effect」——
      本 App 无导航栏 / `safeAreaBar`，系统该效果**实测不渲染**（iOS 27 上状态栏区域完全透明）；
      ② 「按滚动状态显示 / 隐藏」—— 既然正常情况下不可见，该状态判断只会引入闪烁风险
- [x] **性能 / 功耗定点优化**（一轮全仓库审计后的结论，按影响排序）：
      ① 过滤 `apple_codesign::bundle_signing` 的逐文件 `copying file …`（一轮签名上千行，跨 FFI、落盘与界面刷新均需处理）；
      ② 日志 flush 定时器改为**有日志才启动**（原先空闲时亦每 0.2 秒唤醒主线程），内存中保留的日志全文加 512 KB 上限；
      ③ 已签名 IPA 入库、导入 IPA 改为**硬链接**（同一卷内瞬时完成；不再整份复制数百 MB 至 GB 级文件，存储亦不再翻倍）；
      ④ 嵌套重签失败后的「全树结构诊断」仅对前 3 个失败项执行（同因批量失败时不再逐个扫描数千个文件）；
      ⑤ 配对卡片的「本地网络授权探测」在离开卡片或探测失败后立即取消 Bonjour 浏览（不再常驻 mDNS 唤醒网卡）
- [x] **设置页**（底部第三个页签，位于「库」右侧）：两个「执行期间不被打断」开关 ——
      **不息屏**（系统标准 `isIdleTimerDisabled`，前台有效、无需权限）与
      **后台保活**（静音音频 + `UIBackgroundModes: audio`，**切换到后台时进程仍存活、安装可以完成**；
      **不支持锁屏** —— 锁屏后进程会被系统挂起、流程中断，需要长时间无人值守时请改用「不息屏」；
      代价为更耗电并占用音频通道）。两者可同时启用，选择持久化到 `UserDefaults`；
      由 `Model.outcome` 统一驱动（`applyRunGuards`）：流程开始 / 继续时自动开启，完成 / 失败 / 取消时自动恢复，
      且只关闭自身开启的那一个保活（配对流程亦使用同一个 `KeepAlive`，不会被误停）。
      同页还有「关于」：作者 **gugegxy-jpg**（整行可点，跳转 <https://github.com/gugegxy-jpg/SideInjector>）、
      版本号（读 `CFBundleShortVersionString`）与第三方声明入口
- [x] **清理 App 缓存**：「库」页签 →「存储与缓存」显示缓存占用并可一键清理
      （仅清理 `tmp/` 下的工作目录与 `Caches`；证书、已签名 IPA 库、导入的 IPA / dylib、配对文件、日志均保留）
- [x] **自动清理解包残留**：App 启动时（后台队列）自动删除上次运行遗留的 `si_out_*`（解包工作树）、
      `si_in_*`（输入副本）、`si_export_*`（导出产物）、`si_share_*` 等 —— 流程被系统终止时
      （大包容易触发）这些目录会积压数 GB；取消流程时同样清理，释放量大于 50 MB 时在日志中记录一行
- [x] 证书库：多套证书持久化、可编辑，覆盖安装后**路径按当前数据容器自愈**（不会丢失）
- [x] 已签名 IPA 库：签名成功后自动入库，点击即可再次安装
- [x] 导入即入库：IPA / dylib 存入 `Application Support/Inputs/`，不依赖文档选择器提供的临时副本
- [x] **只注入导出（不签名）**：勾选「跳过签名」后仅执行「解压 → 注入 → 改 Bundle → 打包」，
      产出 `<原名>-injected-unsigned.ipa`，并**跳过设备配对与安装**（未签名包无法安装）
- [x] **IPA 库**：本 App 签名产物自动入库；也可**导入其它来源已签名的 IPA**，在列表中点击「安装」直接安装、
      点击「导出」保存 / 分享到「文件」App
- [x] 产物文件名可读：导出为 `<原名>-signed.ipa` / `<原名>-injected-unsigned.ipa`（原先为 `signed_<UUID>.ipa`）
- [x] 设备端自配对（Remote Pairing）：iOS 27+ 无需电脑；配对文件持久化，流程内只执行一次
- [x] **免电脑安装**：RemotePairing 隧道（自配对记录 → TLS-PSK → CDTunnel）+ 用户态 TCP → RSD → AFC + installation_proxy，
      带**真实进度**（installd 返回成功才算完成）；失败时自动回落经典 lockdownd 通路
- [x] 流程控制：任一步骤失败即暂停并保留现场，「继续」从该步续跑；运行中可取消并清理临时文件
- [x] 环境自检卡片：iOS 版本与配对能力、loopback VPN 状态、隧道端口探测（62078 / 27015 / 49152）
- [ ] 注入 Fat / arm64e 主二进制（目前仅支持单切片 arm64）
- [ ] 安装链路的真机验证（刚完成实现，见下）

---

## 安装链路（重点）

设备端安装按下列顺序自动尝试。前提事实：iOS 17+ 的 RSD 端口 `49152` **只接受 TLS-PSK**，
因此「明文直连 49152」不可能成功（发送明文 HTTP 升级请求会被 RST）。

### 1. 免电脑通路（首选）：RemotePairing 隧道 + 用户态 TCP

配对记录由本 App 在**设备上自配对**生成（「设备配对」卡片，iOS 27+），**不需要电脑**：

```
RpPairingFile（自配对产物）
  → RemotePairingClient::validate_pairing    与设备 RP 服务验证已有配对记录（不需要 PIN）
  → client.encryption_key()                  取 TLS-PSK 密钥
  → connect_tls_psk_tunnel_native(stream)    TLS-PSK + CDTunnel 握手 → 隧道
  → Adapter::new(tunnel.into_inner())        隧道里是裸 IPv6 包 → 用户态 TCP 栈（jktcp）
  → AdapterHandle::connect(serverRSDPort)    经隧道连 RSD 端口（端口由隧道握手直接给出）
  → RsdHandshake → com.apple.afc 上传 /PublicStaging
  → com.apple.mobile.installation_proxy      Install（PackageType = Developer）
```

- 设备端无法获得 TUN 权限，因此 TCP 在**用户态**实现（`jktcp`，随 `idevice` 的 `tunnel_tcp_stack` feature 启用）；
- `idevice` 已为 `AdapterHandle` 实现 `RsdProvider`，因此**直接复用**了原有的 AFC + installation_proxy 安装例程；
- 进度由 installation_proxy 回传百分比，经 FFI 轮询上报 UI。

### 2. 经典 lockdownd（回落）

连接 loopback VPN 暴露的本机 `62078`，使用**配对记录**建立会话后执行 AFC 上传 + installation_proxy。
需要 **lockdownd 配对记录**（由 `jitterbugpair` / `idevicepair` 生成），**不能**使用 RemotePairing 的配对文件。

### 诊断日志

安装开始时会先探测端点并写日志，按结果选择通路：

- `install: 端口探测 127.0.0.1:49152 TCP 可连接`
- `rp: 配对记录验证通过` / `rp: 隧道已建立 —— 本端 fdxx::1 / 设备侧 fdxx::2 / RSD 端口 N`
- `rp: RSD 握手成功（…，服务 N 个）` → 随后是上传与安装
- 失败时：`install: 免电脑通路失败（…）：…`，并继续尝试下一条通路

> 判读要点：`127.0.0.1:62078` 直连会返回 `Operation not permitted`（沙盒拒绝直连回环的 lockdownd），
> 经典通路需走 loopback VPN 的对端地址（utun 的 `ifa_dstaddr`，常见为 `10.7.0.1`）——
> 环境自检已按对端地址进行探测。

> 注意：安装为 **Developer 安装**，设备需已开启**开发者模式**（设置 → 隐私与安全性 → 开发者模式）。

---

## 构建

### 方式一：GitHub Actions（推荐；本机为 Windows 亦可出包）

工作流 `.github/workflows/build-ipa.yml` 在 `macos-latest` 上构建：

1. `core/build_xcframework.sh` 编译 Rust core（`aarch64-apple-ios`）
2. `xcodegen generate` 生成工程
3. `xcodebuild archive` + 导出 / 打包 IPA
4. 上传 `SideInjector.ipa`（artifact）**并同时发布到 Release 的 `latest` 标签**

产物下载（推荐使用 Release：走独立 CDN，且支持断点续传）：

```
https://github.com/gugegxy-jpg/SideInjector/releases/latest/download/SideInjector.ipa
```

多线程下载示例：

```bash
aria2c -x16 -s16 -k1M https://github.com/gugegxy-jpg/SideInjector/releases/latest/download/SideInjector.ipa
```

若配置了以下 Secrets，则走「签名导出」流程；否则产出未签名 IPA，用于侧载后自行签名：

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
| 点击「执行」没有反应 | 现在均会**弹窗**说明原因；首页日志中的 `输入检查：…` 行会指出是哪个文件不可用 |
| 覆盖安装后证书「丢失」 | 在「库」页签点击该证书的「编辑」，重新选择 P12 与描述文件并保存即可（本版已实现路径自愈，正常情况下会自动找回） |
| 安装失败 | 先查看**环境自检**卡片：确认 49152 可用、开发者模式已开启；再查看日志中的 `install error: …` |
| 日志中仅 `127.0.0.1:49152` 可连接、`10.7.0.1:49152` **超时** | **loopback VPN 未生效**（StosVPN / SideStore 的描述文件未连接、被系统断开，或该进程被系统回收）。注意 `127.0.0.1` 的「TCP 可连接」属于**假阳性**：本地监听会接受连接，但发送 RSD 升级请求后即被 RST。处理：打开 StosVPN 并保持连接，直至日志中出现 `端口探测 10.7.0.1:49152 TCP 可连接`，然后重试安装 |
| 日志中 `127.0.0.1` 与 `10.7.0.1` 均显示 **Connection refused** | **49152 端口无服务监听**：隧道接口可能仍然存在，但端口映射已失效（实测需重新连接 VPN 或重启设备方可恢复）。处理顺序：① 断开并重新连接 LocalDevVPN；② 断开其它 VPN（iOS 同一时间仅允许一个 VPN 生效）；③ 切换一次飞行模式；④ 重启设备 |
| 安装报 `APIInternalError` / `Mismatched bundle IDs` / `does not match required prefix of … for parent` | **嵌套扩展（.appex）的 Bundle ID 与父 App 不匹配**。iOS 要求扩展的 Bundle ID **必须以父 App 的 ID 为前缀**，仅修改主 App 会导致 installd 拒绝（`Mismatched bundle IDs`）。来源有两种：① 用户自行修改了 Bundle ID —— 工具会自动同步扩展（日志 `嵌套扩展 Bundle ID：PlugIns/…：旧 → 新`，按旧 ID 精确计算后缀）；② **第三方改包自带该错配**（主 App 已被改为 `com.douyin.xyz`，而扩展仍为 `com.ss.iphone.ugc.Aweme.DYShareExtension`，此时不做任何修改亦无法安装）。对 ② 工具**有意不做静默自愈** —— 修改扩展 ID 属于产物语义变更，扩展 ID 被硬编码引用时会导致分享 / 小组件等功能静默失效；改由签名结尾的 `扩展前缀自检：检查 N 个扩展，前缀不符 M 个` 逐项指出（出现 ⚠️ 时请勿继续安装，以免整包上传后仍被拒绝）。修正方法：在流程中执行一次「改 Bundle ID」步骤，**填入与当前相同的 ID 亦可**（工具会按旧 ID 精确修正扩展） |
| 签名报 `I/O error: No such file or directory (os error 2)` | 该错误**不携带路径**（`apple-bundles` 的已知问题）。请复制日志中的以下行：`重签（主可执行）：…`、`重签（资源/二进制）：…`、`重签失败（保留原签名）：…`、`深签（自实现）：完成 X，失败 Y`，以及报错前的 `[apple_…]` 行 |
| 安装报 `MismatchedBundleIDSigningIdentifier` | 某个嵌套代码的**签名标识与其 bundle id 不一致**。日志中 `重签（主可执行）：xxx（CFBundleIdentifier=…）` 一行若标注 `**缺失**`，说明该 bundle 的 Info.plist 缺少 `CFBundleIdentifier`，标识无法修正 |
| 安装报 `MismatchedApplicationIdentifierEntitlement`（跨 App ID 覆盖升级） | **不属于签名问题**。设备上已存在相同 Bundle ID 的 App，但该 App 的 `application-identifier`（即 App ID，形如 `TEAM.com.xxx`）与新包**不一致** —— iOS 不允许使用另一张证书「覆盖升级」。最常见场景：设备上安装的是 **App Store 版本**的同名 App。处理：**先在设备上卸载该 App，再安装**（卸载会清除其数据）；或改用与该 App 相同的证书签名。日志中已将其翻译为中文并给出两个 App ID，查看结尾的 `install error:` 即可。**上传之前还有一次预检**（`install: 预检：设备上已存在相同 Bundle ID 的 App —— …（版本 …，类型 …）`，或 `属全新安装`），可在整包上传前给出提醒；预检只读不写、**不会卸载任何 App** |
| 签名日志中出现 `描述文件：App ID=…；目标 Bundle ID=…` | 描述文件的 App ID 与目标 Bundle ID **不一致**时会出现 `⚠️` 提示：以此方式签出的包，在设备上已有同名 App 时必然被拒（见上一行）。如需安装任意 IPA，请使用**通配（Wildcard）**描述文件；工具会自动将通配 App ID 改写为 `TEAM.<目标 Bundle ID>` |
| App 启动崩溃（注入后） | 被注入的 dylib 必须与宿主 App 使用**同一张证书**重签；宿主需带 `get-task-allow` 等 entitlement |

---

## 已知问题 / 限制

1. **嵌套 bundle 已不再走 `apple-codesign` 的「整 bundle 签名」**：实测（一次 93 项的流程）它对本 IPA 中**所有带主可执行文件**的项（framework / 带可执行的 bundle）都会在中途抛出**不带路径**的 `ENOENT (os error 2)` —— 失败的均为「有主可执行」的项，而成功的 30 项全部是无主可执行的资源 bundle，说明它在功能正常的 bundle 签名的资源走查 / 文件搬运环节失败（`walk_and_seal_directory`）。现改为：这些项**只重签主可执行文件**（`MachOSigner` + `set_binary_identifier` + 嵌回原有 `CodeResources`），绕开该环节。若仍有项失败，日志会逐项给出原因与结构诊断。
2. **安装链路已完整走通**：RP 自配对 → 隧道（`rp: 隧道已建立 …`）→ RSD 握手（64 个服务）→ AFC 分块上传 `/PublicStaging` → `installation_proxy` 安装。实机上一次 637 MB 的包已能完成上传并进入 installd，**签名校验（`MismatchedBundleIDSigningIdentifier`）已不再是障碍**；目前剩余的失败均属于**设备端策略**：`MismatchedApplicationIdentifierEntitlement` —— 设备上已有相同 Bundle ID 的 App，且该 App 由**另一张证书**签名，iOS 拒绝换证书覆盖升级（App Store 版本的同名 App 必然如此）。处理办法只有一个：**先在设备上卸载该 App**。工具已将这类错误翻译为中文并附上两个 App ID（见排障表）。
3. 签名阶段会打印 `描述文件：name=…；App ID=…；团队=…；目标 Bundle ID=…`。描述文件为**通配**时，工具会自动将 `application-identifier` / `keychain-access-groups` 改写为 `TEAM.<目标 Bundle ID>`（照抄 `TEAM.*` 是无效值）；描述文件为固定 App ID 且与目标 Bundle ID 不一致时会给出 `⚠️`，因为此类包在设备上已有同名 App 时必然被拒。
4. `InstallEngine` 中旧的经典 lockdownd / usbmux 实现已是**死代码**，待清理。
5. 注入仅支持单切片 arm64 主二进制；Fat / arm64e 未实现。
6. 仅对普通第三方 IPA 有效；系统 App 注入在无越狱环境下不可行。
7. 本工具自身必须侧载，并需放宽沙盒 entitlement（见 `SideInjector.entitlements`）。

---

## 代码出处与致谢

本项目**参考 / 借鉴了以下开源项目**，特此注明出处。若相关作者认为署名方式不妥，请提交 Issue，将立即更正。

> 完整的第三方声明（许可条款要点、逐文件对应关系、再分发时的义务）见
> **[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)**；各源码文件头部也有对应出处的简版标注。

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

- 允许使用、复制、修改，并**允许以源码形式再分发** —— 须附带该许可证与版权声明，且**标明所做修改**；
- **禁止商业使用**（商业使用需另行书面授权）；
- **禁止再分发其官方构建 / IPA**（重新打包、重签名、镜像等均不允许）；
- **必须署名**：须标注 “**SideInstaller by FrizzleM**” 并链接官方仓库（本条已由本 README 满足）。

> 因此：上表所列**参考其写成的部分不适用 MIT**，并受「禁止商业使用」约束。如需商用，请先联系 FrizzleM 取得授权，或将这些部分替换为独立实现（`core/src/pair.rs` 与安装链路已建立在 MIT 许可的 `idevice` crate 之上，替换成本可控）。

### 2. indygreg/apple-platform-rs —— `apple-codesign`（MPL-2.0，库依赖）

<https://github.com/indygreg/apple-platform-rs>

- `core/src/sign.rs` 以**库形式**链接 `apple-codesign`（0.27，`default-features = false`）完成重签。之所以不调用 `rcodesign` 命令行：iOS 禁止 App `fork/exec` 子进程；
- `core/src/sign.rs` 中的**签名前结构诊断**，是阅读同仓库 `apple-bundles` 的 `DirectoryBundle` 实现后，按其 bundle 判定规则（是否 `shallow`、优先 `Resources/Info.plist`、嵌套 bundle 候选）写成的镜像检查；
- `core/src/logbridge.rs` 将其 `log` 输出桥接到 App 日志，用于定位其**不带路径**的 IO 错误。

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

- **SideStore / AltStore**：用于将 SideInjector 本身侧载进设备；
- **StosVPN / SideStore 的 loopback VPN 描述文件**：为设备端安装提供到本机 RSD 的回环通道。

---

## 许可证

- **本仓库自有代码**：MIT；
- **参考 SideInstaller 写成的部分**（见上表）：适用 *SideInstaller License* —— 允许以源码形式使用 / 修改 / 分发并须署名，**禁止商业使用**；
- **第三方依赖**：`apple-codesign`（MPL-2.0）、`idevice`（MIT）、`zip` / `plist` / `log` / `tokio` / `serde_json` / `anyhow`（MIT 或 Apache-2.0）。

署名声明：

> 本项目包含参考 **SideInstaller by FrizzleM**（<https://github.com/FrizzleM/SideInstaller>）写成的实现。该部分按其 *SideInstaller License*（Copyright © 2026 FrizzleM）发布，**禁止商业使用**，且不得再分发其官方构建 / IPA。
