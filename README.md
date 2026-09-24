# SideInjector

一个**跑在 iPhone 上**的 iOS App：在设备内部完成

```
导入证书 → 导入 IPA → 注入 dylib → 改 Bundle → 重签 → 打包 → 设备配对 → 安装到本机
```

即：**不需要电脑**，用你自己的开发证书给一颗 IPA 重签并装回同一台设备。

> 与桌面工具 `ipatool` 完全独立，本目录是单独项目，不要并入原工具。
> 仓库：https://github.com/gugegxy-jpg/SideInjector

**支持的系统：iOS 17.0 及以上。** 本工具**自身**必须运行在 iOS 17 及以上：设备端安装走的是
iOS 17 才引入的 **CoreDevice / RSD（49152）** 链路。iOS 17 以下没有这条链路，只能走经典
lockdownd(62078) 通路，而那条路**未经实机验证**，因此**不支持 iOS 16 及以下**——低于 iOS 17 的设备
装不上本 App，`project.yml` 的部署目标也是 `17.0`。

---

## 快速开始（使用）

1. **装 SideInjector 本身**（必须侧载，不能上 App Store）。CI 产出的未签名 IPA 用 SideStore / AltStore / Sideloadly 等装上即可。
2. 打开 App → 首页 **证书** 区 → 「导入」选择你的 `.p12` + `.mobileprovision` + p12 密码（可保存多套，之后下拉直选）。
3. 首页 **输入** 区 → 「导入」选择要处理的 `.ipa`（导入即入库，之后可在下拉里重复选择）；需要注入的 `.dylib` 同样导入（可多选）。
4. 需要改 Bundle ID / 显示名时可填。
5. 点「**执行**」，依次走完 7 个阶段。
   - **只想注入、不想签名**：在证书区勾选「跳过签名（只注入后导出）」，流程只跑到「打包 IPA」就结束，
     产出未签名 IPA，再用「导出 / 分享」保存到「文件」App（该模式不会触发设备配对与安装）。
6. 之后可直接在「**库**」页签点击已签名的 IPA →「安装」，无需重跑注入/签名；
   「**库**」页签还支持「**导入已签名 IPA**」——把别处签好的包导入进来，同样可以一键安装或再导出。

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
   ├─ sign       进程内 apple-codesign 0.27 重签（嵌套项只重签主可执行 + 主 App 浅签）
   ├─ pair       设备端自配对（Remote Pairing，PairableHost + RpPairingFile）
   ├─ install    设备端安装（CoreDevice / RSD 链路）
   └─ logbridge  把 apple-codesign / apple-bundles 内部日志转发到 App 日志
```

**为什么签名不走外部二进制**：iOS 禁止 App `fork/exec` 子进程（`spawn` 报 `operation not permitted`），所以不能调用 `rcodesign` 命令行，只能把 `apple-codesign` 作为库链接进来，`default-features = false` 关掉公证相关重依赖。

---

## 功能状态

- [x] IPA 解包 / 打包（保留符号链接与权限位）
- [x] 主二进制注入 dylib，支持一次注入多个（注入名取各自文件名；重名自动加后缀）
- [x] 改 Bundle ID / 显示名：导入 IPA 后把「当前值」作为**提示**显示（**不预填输入框**，留空仍然表示不改），
      且**只有真正改过才写 `Info.plist`**；嵌套扩展的 Bundle ID 只在主 ID 变了时连带同步，
      另配**显式开关**「同步嵌套扩展 Bundle ID」用于修复第三方改包自带的错配（扩展 ID 是运行时身份，不做自动改写）
- [x] 进程内重签：`apple-codesign` 0.27。嵌套项（framework / appex）**逐个只重签主可执行文件**，
      并把签名标识强制设为该 bundle 的 `CFBundleIdentifier`（否则 installd 报 `MismatchedBundleIDSigningIdentifier`）；
      资源 bundle 仍按 bundle 级签名（只封资源）；最后**浅签主 App**，把全部内容封进主 App 的 `CodeResources`
- [x] **浅签阶段会覆盖嵌套签名**，已针对性处理：`apple-codesign` 的「浅签」并非只复制嵌套代码，
      而是会把 app 内所有嵌套 Mach-O 逐个重签（`signing Mach-O file Frameworks/xxx.framework/xxx`），
      且该路径**不继承 `Main` 作用域标识** → 标识会按二进制名重算。现为每个嵌套 Mach-O 登记
      **路径作用域标识**（`SettingsScope::Path("Frameworks/xxx.framework/xxx")`），浅签时用我们给的值
- [x] **签名标识自检**：签完自行解析新签名的 `CodeDirectory` 把标识读回来逐项比对，
      收尾在**最终会打进 IPA 的那份 app** 上汇总（`签名标识自检：检查 N 项，不匹配 M 项`，0 才算全对）
- [x] **日志分两级 + 不再拖卡界面**：**重要日志**（阶段、汇总、自检、错误）显示在首页日志卡片；
      **细节日志**（逐项进度、apple-codesign / goblin / idevice 内部输出、RSD 服务清单等诊断）
      只写后台日志文件 `Application Support/Logs/sideinjector.log`。Rust 侧过滤 `goblin` /
      `apple_codesign::code_resources` 的逐条 dump；Swift 侧**每 0.2 秒合并提交一次**、
      日志卡片独立观察 `LogStore`、界面只渲染末尾 200 行
- [x] **日志管理**：首页日志卡片可「复制」完整日志（含细节日志的文件快照，直接进剪贴板，并提示行数 / 大小）、
      「导出」（分享 / 存到「文件」）、「清空」（内存 + 文件，超过 4 MB 自动轮转保留一份 `sideinjector.1.log`）。
      注：**不提供「查看全部」**——几千行文本一次性交给 `Text` 排版渲染不出来；那个入口的用途本来也只是
      「把日志拿出来」，所以直接做成复制
- [x] **顶部状态实时显示**：标题栏副标题为 `iOS 版本 · LocalDevVPN 已连接/未连接 · WiFi 已连接/未连接`
      （原来是「Liquid Glass · iOS 26+」这类外观描述，对使用者没有信息量）。用 `NWPathMonitor` 实时刷新，
      开关 WiFi / 连接或断开 VPN 都会立刻反映；判据与「环境自检」一致：**LocalDevVPN 看的是
      "隧道上带 10.7.x.x 地址"**，而不是"存在 utun/ipsec/ppp 隧道接口" —— 后者会把 Shadowrocket
      这类普通 VPN 也当成 LocalDevVPN 已连接（实测踩过）。
      说明：**安装链路不访问外网**——全程是本机内的 loopback VPN 隧道 → RSD → AFC/installation_proxy → installd，
      WiFi 本身不提供通路（连自己的 LAN 地址仍走本机回环，沙盒限制相同）；安装开始时也会记一行
      `install: 网络环境：WiFi … · LocalDevVPN …`，便于事后对照
- [x] **状态栏蒙版**：内容（标题、卡片）滚到系统状态栏下面时，时钟/电量不再与 App 文字压字。
      **常驻铺着、但平时看不出来**：只模糊、不叠色 —— 用 UIKit 纯模糊 `UIBlurEffect(style: .regular)`
      （`BlurOnly` + `UIViewRepresentable`）。模糊一层平滑渐变 ≈ 原来的渐变，所以空着时看不见；
      内容滑到它下面立刻呈现毛玻璃感。**刻意不用** `.ultraThinMaterial` / `.glassEffect`：它们除模糊外
      还叠一层填充色（玻璃还带高光），在深色渐变背景上会浮出一条能看出来的"带子"。**强度也不能整条一样**：
      模糊会轻微去色，等强时边界仍看得出来，所以强度做成自上而下的渐变 —— 顶端约 0.5（看得出糊了、
      但不至于像一块实心玻璃），往下递减到 0，越往下越淡直到与背景无差；想更淡/更明显就调 `StatusBarMask`
      里 mask 那几个 opacity。高度 = `safeAreaInsets.top + 14`，整层 `allowsHitTesting(false)`（不吃点击），
      两个页签都受保护。曾试过两条岔路，都撤了：① 「iOS 26+ 交给系统的 scroll edge effect」——
      本 App 无导航栏 / `safeAreaBar`，系统那层**实测不出现**（iOS 27 状态栏完全透明）；
      ② 「按滚动状态显隐」—— 既然平时看不出来，那套状态判断只会带来闪烁风险
- [x] **性能 / 功耗定点优化**（一轮全仓库审计后的结论，按影响排序）：
      ① 过滤 `apple_codesign::bundle_signing` 的逐文件 `copying file …`（一轮签名上千行，跨 FFI + 落盘 + 界面刷新都要吃一遍）；
      ② 日志 flush 定时器改为**有日志才起**（原来空闲也每 0.2 秒唤醒主线程），内存里保留的日志全文加 512 KB 上限；
      ③ 已签名 IPA 入库、导入 IPA 改为**硬链接**（同一卷内瞬时完成；不再整份复制几百 MB～GB，存储也不再翻倍）；
      ④ 嵌套重签失败后的「全树结构诊断」只对前 3 个失败项做（同因批量失败时不再逐个白扫几千个文件）；
      ⑤ 配对卡片的「本地网络授权探测」在离开卡片 / 探测失败后立即取消 Bonjour 浏览（不再常驻 mDNS 唤醒网卡）
- [x] **设置页**（底部第三个页签，位于「库」右侧）：两个「执行期间不被打断」开关 ——
      **不息屏**（系统标准 `isIdleTimerDisabled`，前台有效、不需权限）与
      **后台保活**（静音音频 + `UIBackgroundModes: audio`，**切后台时进程仍存活、安装能跑完**；
      **不支持锁屏** —— 锁屏后进程会被系统挂起、流程会断，需长时间无人值守请改用「不息屏」；
      代价是更耗电并占用音频通道）。两者可同时开，选择持久化到 `UserDefaults`；
      由 `Model.outcome` 统一驱动（`applyRunGuards`）：流程开始 / 继续自动开启，完成 / 失败 / 取消自动恢复，
      且只关自己开的那一个保活（配对流程也用同一个 `KeepAlive`，不会误停）。
      同页还有「关于」：作者 **gugegxy-jpg**（整行可点，跳 <https://github.com/gugegxy-jpg/SideInjector>）、
      版本号（读 `CFBundleShortVersionString`）与第三方声明入口
- [x] **清理 App 缓存**：「库」页签 →「存储与缓存」显示缓存占用并可一键清理
      （只清 `tmp/` 下的工作目录与 `Caches`；证书、已签名 IPA 库、导入的 IPA / dylib、配对文件、日志都保留）
- [x] **自动清理解包残留**：App 启动时（后台队列）自动删掉上次运行遗留的 `si_out_*`（解包工作树）、
      `si_in_*`（输入副本）、`si_export_*`（导出产物）、`si_share_*` 等 —— 流程被系统杀掉时
      （大包很容易触发）这些会积压几个 GB；取消流程时同样清理，释放量 >50 MB 会在日志里报一句
- [x] 证书库：多套证书持久化、可编辑、覆盖安装后**路径按当前数据容器自愈**（不会丢）
- [x] 已签名 IPA 库：签名成功自动入库，点击即可再次安装
- [x] 导入即入库：IPA / dylib 落到 `Application Support/Inputs/`，不依赖文档选择器给的临时副本
- [x] **只注入导出（不签名）**：勾选「跳过签名」后只跑「解压 → 注入 → 改 Bundle → 打包」，
      产出 `<原名>-injected-unsigned.ipa`，并**跳过设备配对与安装**（未签名包无法安装）
- [x] **IPA 库**：本 App 签名产物自动入库；也可**导入别处已经签名好的 IPA**，列表里点「安装」直接装、
      点「导出」保存 / 分享到「文件」App
- [x] 产物文件名可读：导出为 `<原名>-signed.ipa` / `<原名>-injected-unsigned.ipa`（原先为 `signed_<UUID>.ipa`）
- [x] 设备端自配对（Remote Pairing）：iOS 27+ 无需电脑；配对文件持久化，流程内只做一次
- [x] **免电脑安装**：RemotePairing 隧道（自配对记录 → TLS-PSK → CDTunnel）+ 用户态 TCP → RSD → AFC + installation_proxy，
      带**真实进度**（installd 返回成功才算完成）；失败时自动回落经典 lockdownd 通路
- [x] 流程控制：任一步失败即暂停并保留现场，「继续」从该步续跑；运行中可取消并清理临时文件
- [x] 环境自检卡片：iOS 版本与配对能力、loopback VPN 状态、隧道端口探测（62078 / 27015 / 49152）
- [ ] 注入 Fat / arm64e 主二进制（目前仅单切片 arm64）
- [ ] 安装链路的真机验证（刚完成实现，见下）

---

## 安装链路（重点）

设备端安装按下列顺序自动尝试。前提事实：iOS 17+ 的 RSD 端口 `49152` **只接受 TLS-PSK**，
所以「明文直连 49152」不可能成功（发明文 HTTP 升级请求会被 RST）。

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

- 设备端拿不到 TUN 权限，因此 TCP 在**用户态**实现（`jktcp`，随 `idevice` 的 `tunnel_tcp_stack` feature 启用）；
- `idevice` 已为 `AdapterHandle` 实现 `RsdProvider`，因此**直接复用**了原有的 AFC + installation_proxy 安装例程；
- 进度由 installation_proxy 回传百分比，经 FFI 轮询上报 UI。

### 2. 经典 lockdownd（回落）

连 loopback VPN 暴露的本机 `62078`，用**配对记录**建立会话后 AFC 上传 + installation_proxy。
需要 **lockdownd 配对记录**（`jitterbugpair` / `idevicepair` 生成的那种），**不能**用 RemotePairing 的配对文件。

### 诊断日志

安装开始时会先探测端点并写日志，按结果选择通路：

- `install: 端口探测 127.0.0.1:49152 TCP 可连接`
- `rp: 配对记录验证通过` / `rp: 隧道已建立 —— 本端 fdxx::1 / 设备侧 fdxx::2 / RSD 端口 N`
- `rp: RSD 握手成功（…，服务 N 个）` → 随后是上传与安装
- 失败时：`install: 免电脑通路失败（…）：…`，并继续尝试下一条通路

> 判读要点：`127.0.0.1:62078` 直连会返回 `Operation not permitted`（沙盒拒绝直连回环的 lockdownd），
> 经典通路要走 loopback VPN 的对端地址（utun 的 `ifa_dstaddr`，常见 `10.7.0.1`）——环境自检已按对端地址探测。

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
| 日志里只有 `127.0.0.1:49152` 可连接、`10.7.0.1:49152` **超时** | **loopback VPN 没在工作**（StosVPN / SideStore 的描述文件没连上、被系统断开，或那个进程被系统回收）。注意 `127.0.0.1` 的「TCP 可连接」是**假阳性**：本地监听会接受连接，但一发 RSD 升级请求就被 RST。处理：打开 StosVPN 并保持连接，直到日志里出现 `端口探测 10.7.0.1:49152 TCP 可连接`，再重试安装 |
| 安装报 `APIInternalError` / `Mismatched bundle IDs` / `does not match required prefix of … for parent` | **嵌套扩展（.appex）的 Bundle ID 与父 App 不匹配**。iOS 要求扩展的 Bundle ID **必须以父 App 的 ID 为前缀**，只改主 App 会让 installd 拒绝（`Mismatched bundle IDs`）。来源两种：① 你自己改了 Bundle ID —— 工具会自动同步扩展（日志 `嵌套扩展 Bundle ID：PlugIns/…：旧 → 新`，用旧 ID 精确算后缀）；② **第三方破包自带**（主 App 被改成 `com.douyin.xyz`、扩展还是 `com.ss.iphone.ugc.Aweme.DYShareExtension`，此时你什么都不改也装不上）。对 ② 工具**故意不做静默自愈**——改扩展 ID 属于产物语义变更，扩展 ID 被硬编码引用时会让分享/小组件等功能静默失效；而是由签名结尾的 `扩展前缀自检：检查 N 个扩展，前缀不符 M 个` 逐个点名（⚠️ 出现时先别装，省得白传整包）。修法：在流程里把「改 Bundle ID」那一步跑一次，**填与当前相同的 ID 也可以**（工具会按旧 ID 精确改好扩展） |
| 签名报 `I/O error: No such file or directory (os error 2)` | 这个错误**不带路径**（`apple-bundles` 的老问题）。请复制日志里这几类行：`重签（主可执行）：…`、`重签（资源/二进制）：…`、`重签失败（保留原签名）：…`、`深签（自实现）：完成 X，失败 Y`、以及报错前的 `[apple_…]` 行 |
| 安装报 `MismatchedBundleIDSigningIdentifier` | 某个嵌套代码的**签名标识 ≠ 它的 bundle id**。看日志里 `重签（主可执行）：xxx（CFBundleIdentifier=…）` 一行标了 `**缺失**` 就说明该 bundle 的 Info.plist 没有 `CFBundleIdentifier`，标识无法修正 |
| 安装报 `MismatchedApplicationIdentifierEntitlement`（跨 App ID 覆盖升级） | **不是签名问题**。设备上已装同 Bundle ID 的 App，但那个 App 的 `application-identifier`（即 App ID，形如 `TEAM.com.xxx`）与新包的**不是同一个**——iOS 不允许换证书「覆盖升级」。最常见场景：设备上装的是 **App Store 正版**同名 App。处理：**先在设备上卸载那个 App，再安装**（卸载会清掉它的数据）；或改用与它同一张证书签名。日志里已把它翻译成中文并给出两个 App ID，看结尾的 `install error:` 即可。**上传之前还有一次预检**（`install: 预检 —— 设备上已存在同 Bundle ID 的 App：…（版本 …；类型 …）`，或 `属全新安装`），能在白传整包之前就提醒你；预检只读不写、**不会卸载任何 App** |
| 签名日志里 `描述文件：App ID=…；目标 Bundle ID=…` | 描述文件的 App ID 与目标 Bundle ID **不一致**时会有 `⚠️` 提示：这样签出来的包在设备上已有同名 App 时必然被拒（见上一行）。想装任意 IPA，请用**通配（Wildcard）**描述文件；工具会自动把通配 App ID 改写为 `TEAM.<目标 Bundle ID>` |
| App 启动崩溃（注入后） | 被注入的 dylib 必须与宿主 App 用**同一张证书**重签；宿主需带 `get-task-allow` 等 entitlement |

---

## 已知问题 / 限制

1. **嵌套 bundle 已不再走 `apple-codesign` 的「整 bundle 签名」**：实测（一次 93 项的流程）它对本 IPA 里**所有带主可执行文件**的项（framework / 带可执行的 bundle）都会在中途抛**不带路径**的 `ENOENT (os error 2)`——失败的清一色是"有主可执行"的项，而成功的 30 项全是无主可执行的资源 bundle，说明它在功能正常的 bundle 签名的资源走查 / 文件搬运环节挂掉（`walk_and_seal_directory`）。现改为：这些项**只重签主可执行文件**（`MachOSigner` + `set_binary_identifier` + 嵌回原有 `CodeResources`），绕开该环节。若仍有项失败，日志会逐项给出原因与结构诊断。
2. **安装链路已完整走通**：RP 自配对 → 隧道（`rp: 隧道已建立 …`）→ RSD 握手（64 个服务）→ AFC 分块上传 `/PublicStaging` → `installation_proxy` 安装。实机上一次 637 MB 的包已能上传完并进入 installd，**签名校验（`MismatchedBundleIDSigningIdentifier`）不再是拦路虎**；目前剩下的失败都属于**设备端策略**：`MismatchedApplicationIdentifierEntitlement` —— 设备上已有同 Bundle ID 的 App，且它是用**另一张证书**签的，iOS 拒绝换证书覆盖升级（App Store 正版同名 App 必然如此）。处理办法只有一个：**先在设备上卸载那个 App**。工具已把这类错误翻译成中文并附上两个 App ID（见排障表）。
3. 签名阶段会打印 `描述文件：name=…；App ID=…；团队=…；目标 Bundle ID=…`。描述文件是**通配**时，工具会自动把 `application-identifier` / `keychain-access-groups` 改写成 `TEAM.<目标 Bundle ID>`（照抄 `TEAM.*` 是无效值）；描述文件是固定 App ID 且与目标 Bundle ID 不一致时会给出 `⚠️`，因为那种包在设备上已有同名 App 时必然被拒。
3. `InstallEngine` 里旧的经典 lockdownd / usbmux 实现已是**死代码**，待清理。
4. 注入仅支持单切片 arm64 主二进制；Fat / arm64e 未实现。
5. 仅对普通第三方 IPA 有效；系统 App 注入无 jailbreak 不可行。
6. 本工具自身必须侧载，并需放宽沙盒 entitlement（见 `SideInjector.entitlements`）。

---

## 代码出处与致谢

本项目**参考/借鉴了以下开源项目**，特此注明出处。若你是相关作者、认为署名方式不妥，请开 Issue，我会立即更正。

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
