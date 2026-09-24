//! 设备端安装 —— 走 CoreDevice / RSD 路径（iOS 17+ 的本机安装通道）。
//!
//! 为什么不是经典 lockdownd：
//!   实测（App 内端口探测）在设备自身只能连上 **RSD 49152**，而 lockdownd 62078 /
//!   usbmuxd 27015 在 127.0.0.1、VPN 地址（10.7.0.0）、WiFi 地址上全部超时。
//!   也就是说 iOS 17+ 的设备端安装只有 RSD 这一条路。
//!
//! 代码出处（开源署名）：协议实现全部来自 `idevice` crate
//!   —— https://github.com/jkcoxson/idevice （MIT，Copyright © Jackson Coxson）。
//!   本文件未使用 SideInstaller 的代码（安装链路的实现已由 `idevice` 提供）。
//!
//! 链路：
//!   TcpStream::connect(127.0.0.1:49152)
//!     → RsdHandshake::new(stream)                      握手，拿到服务表（含各服务端口）
//!     → IpAddr 作为 RsdProvider（其 connect_to_service_port 就是普通 TCP）
//!         ├─ com.apple.afc                  上传 IPA 到 /PublicStaging
//!         └─ com.apple.mobile.installation_proxy   Install（PackageType=Developer）
//!
//! 进度：installation_proxy 会回百分比，这里写进 INSTALL_PERCENT，Swift 侧轮询。

use crate::log_msg;
use anyhow::{bail, Context, Result};
use idevice::services::rsd::RsdHandshake;
use idevice::utils::installation::install_package_with_callback_rsd;
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};
use tokio::net::TcpStream;

/// RSD（RemoteServiceDiscovery / remoted）端口。
pub const RSD_PORT: u16 = 49152;

/// 安装进度：-1=未开始，0..100=进行中，100=完成。
static INSTALL_PERCENT: AtomicI32 = AtomicI32::new(-1);

/// 供 Swift 轮询的进度值。
pub fn install_percent() -> i32 {
    INSTALL_PERCENT.load(Ordering::Relaxed)
}

fn set_percent(v: i32) {
    INSTALL_PERCENT.store(v, Ordering::Relaxed);
}

/// 设备端安装：把已签名的 IPA 装到本机。
///
/// 这是阻塞调用（内部自建 tokio 运行时），由 Swift 侧放到后台线程执行，
/// 进度通过 [`install_percent`] 轮询。
pub fn install_ipa(ipa: &Path, pairing: Option<&Path>) -> Result<()> {
    if !ipa.exists() {
        bail!("待安装的 IPA 不存在：{}", ipa.display());
    }
    set_percent(0);
    // 包大小写进日志（重要级）：超大包的问题（内存/磁盘/耗时）全靠它判断。
    let size = std::fs::metadata(ipa).map(|m| m.len()).unwrap_or(0);
    let size_text = if size >= 1024 * 1024 * 1024 {
        format!("{:.1} GB", size as f64 / 1024.0 / 1024.0 / 1024.0)
    } else {
        format!("{:.0} MB", size as f64 / 1024.0 / 1024.0)
    };
    log_msg(&format!(
        "install: 待安装 {}（{}）；配对文件：{}",
        ipa.display(),
        size_text,
        pairing
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "未提供".to_string())
    ));

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("创建 tokio 运行时失败")?;

    let ipa = ipa.to_path_buf();
    let pairing = pairing.map(|p| p.to_path_buf());
    let result = rt.block_on(async move { install_async(&ipa, pairing.as_deref()).await });
    match result {
        Ok(()) => {
            set_percent(100);
            log_msg("install: 安装完成（installd 返回成功）");
            Ok(())
        }
        Err(e) => {
            set_percent(-1);
            log_msg(&format!("install error: {e:#}"));
            Err(e)
        }
    }
}

/// 把 installd 返回的原始错误翻译成**可执行的处理建议**。
///
/// 为什么需要：installd 的失败经 `idevice` 传回来是 `UnknownErrorType("<英文>")` 这样的裸串，
/// 用户看不懂，而真正的原因往往只有一个。匹配不到就返回 `None`（不臆测）。
fn explain_install_error(raw: &str) -> Option<String> {
    // 取 `after` 之后、`before` 之前的片段（用于从 installd 文案里抠出两个 App ID）。
    fn between(text: &str, after: &str, before: &str) -> Option<String> {
        let rest = text.split_once(after)?.1;
        let end = rest.find(before)?;
        Some(rest[..end].to_string())
    }

    if raw.contains("MismatchedApplicationIdentifierEntitlement") {
        let new_id = between(raw, "entitlement string (", ")").unwrap_or_else(|| "(未知)".into());
        let old_id = between(
            raw,
            "installed application's application-identifier string (",
            ")",
        )
        .unwrap_or_else(|| "(未知)".into());
        return Some(format!(
            "══ 安装被 iOS 拒绝：跨 App ID 覆盖升级 ══\n\
             设备上已装的同名 App：{old_id}\n\
             本次要装的：          {new_id}\n\
             原因：两者 Bundle ID 相同，但 application-identifier（带证书团队前缀的 App ID）不同。\n\
             　　 iOS 不允许用另一张证书去「覆盖升级」已装好的同名 App；若设备上装的是\n\
             　　 App Store 正版（或之前用别家证书装的改版），必然报这一条。\n\
             处理（二选一）：\n\
             　 ① 先在设备上把那个 App 卸载（长按图标 → 删除），再重新安装；\n\
             　 ② 改用与它同一张证书 + 描述文件来签名。\n\
             注意：卸载会清掉该 App 的数据；卸载后仍可安装本工具签出的改版。"
        ));
    }
    if raw.contains("MismatchedBundleIDSigningIdentifier") {
        return Some(
            "══ 安装被 iOS 拒绝：签名标识与 Bundle ID 不一致 ══\n\
             某个嵌套代码（framework / appex）的签名标识 ≠ 它的 CFBundleIdentifier。\n\
             看日志里 `重签（主可执行）：…（CFBundleIdentifier=…）` 一行是否标了 `**缺失**`，\n\
             以及结尾的 `深签（自实现）：完成 X，失败 Y` 是否为 0 失败。"
                .to_string(),
        );
    }
    if raw.contains("ApplicationVerificationFailed") || raw.contains("InvalidSignature") {
        return Some(
            "══ 安装被 iOS 拒绝：签名校验失败 ══\n\
             常见原因：签名证书与描述文件不匹配（例如描述文件的 App ID 与目标 Bundle ID 不同）、\n\
             证书已过期/被吊销，或设备不在描述文件的设备列表里。\n\
             请核对日志里 `描述文件：name=…；App ID=…；团队=…；目标 Bundle ID=…` 一行。"
                .to_string(),
        );
    }
    if raw.contains("app extension placeholder") || raw.contains("Mismatched bundle IDs") {
        let ext_id = between(raw, "with bundle ID ", " that does not match")
            .unwrap_or_else(|| "(未知)".into());
        let parent_id =
            between(raw, "required prefix of ", " for parent").unwrap_or_else(|| "(未知)".into());
        return Some(format!(
            "══ 安装被 iOS 拒绝：扩展的 Bundle ID 与父 App 不匹配 ══\n\
             扩展：  {ext_id}\n\
             父 App：{parent_id}\n\
             原因：iOS 要求**扩展（.appex）的 Bundle ID 必须以父 App 的 Bundle ID 为前缀**。\n\
             　　 通常是「改了主 App 的 Bundle ID、但没同步改嵌套扩展」造成的。\n\
             处理：本工具改 Bundle ID 时会自动同步全部扩展（日志里 `嵌套扩展 Bundle ID：PlugIns/…：旧 → 新`）。\n\
             　　 重新执行一次「改 Bundle ID → 注入 → 签名」流程即可；签名结尾还有\n\
             　　 `扩展前缀自检：检查 N 个扩展，前缀不符 M 个` 可供核对。"
        ));
    }
    None
}

async fn install_async(ipa: &Path, pairing: Option<&Path>) -> Result<()> {
    // 通路 0（免电脑，优先）：RemotePairing 隧道 → 用户态 TCP → RSD → AFC + installation_proxy。
    //
    // 设备端自连 RSD 端口（49152）**要 TLS-PSK**，密钥来自 RemotePairing 会话；
    // 配对记录可以在设备上自配对生成（本 App「设备配对」），所以这条路不需要电脑。
    // 先用带超时的 TCP 探测筛掉不可达地址，避免对它们做长时间连接等待。
    let mut rp_hosts: Vec<Ipv4Addr> = Vec::new();
    for host in probe_hosts() {
        let (ok, note) = probe_endpoint(host, RSD_PORT, false).await;
        // 端口探测是逐地址的诊断细节：只进后台日志文件，界面不显示。
        crate::log_detail(&format!("install: 端口探测 {note}"));
        if ok {
            rp_hosts.push(host);
        }
    }
    // 被 iOS **策略**拒绝的原因（例如跨 App ID 覆盖升级）：通路本身是通的，这类原因才是
    // 真因，而用户通常只复制日志尾部 —— 收集起来，最后放进 `install error:` 一行里。
    let mut hints: Vec<String> = Vec::new();
    if let Some(pairing) = pairing {
        for host in rp_hosts.iter().copied() {
            log_msg(&format!(
                "install: 尝试免电脑通路（RP 隧道 + 用户态 TCP，{host}）"
            ));
            match crate::rp::install(ipa, pairing, host, report_percent).await {
                Ok(()) => {
                    log_msg("install: 免电脑通路安装成功");
                    return Ok(());
                }
                Err(e) => {
                    let raw = format!("{e:#}");
                    log_msg(&format!("install: 免电脑通路失败（{host}）：{raw}"));
                    if let Some(hint) = explain_install_error(&raw) {
                        hints.push(hint);
                    }
                }
            }
        }
    } else {
        log_msg("install: 未提供配对文件，跳过免电脑通路（RP 隧道需要自配对记录）");
    }

    // 先探测再动手。原因（实测）：
    //   - 设备自连 49152，TCP 能连上，但发 RSD 升级请求后被 RST → 对端不是明文 remoted；
    //   - 127.0.0.1:62078 直接返回 EPERM（沙盒拒绝直连回环的 lockdownd），
    //     但 loopback VPN 的对端地址（10.7.0.1）上另有出口。
    // 所以这里分别探「哪个地址是 RSD」与「哪个地址的 lockdownd 能应答」，再按可用性选通路。
    let mut rsd_host: Option<Ipv4Addr> = None;
    for host in probe_hosts() {
        let (ok, note) = probe_endpoint(host, RSD_PORT, true).await;
        log_msg(&format!("install: RSD 探测 {note}"));
        if ok && rsd_host.is_none() {
            rsd_host = Some(host);
        }
    }

    let mut lockdown_host: Option<Ipv4Addr> = None;
    for host in probe_hosts() {
        let (ok, note) = probe_lockdown(host).await;
        log_msg(&format!("install: lockdownd 探测 {note}"));
        if ok && lockdown_host.is_none() {
            lockdown_host = Some(host);
        }
    }

    let mut errors: Vec<String> = Vec::new();

    // 通路 1：RSD（iOS 17+ 正统链路，需对端确实是明文 remoted）。
    if let Some(host) = rsd_host {
        log_msg(&format!("install: 尝试 RSD 通路（{host}:{RSD_PORT}）"));
        match rsd_install(ipa, host).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                log_msg(&format!("install: RSD 通路失败，转经典通路：{e:#}"));
                errors.push(format!("RSD（{host}）：{e:#}"));
            }
        }
    }

    // 通路 2：经典 lockdownd（loopback VPN 暴露本机 lockdownd + 配对记录）。
    // 这是 SideStore + StosVPN 在设备端自装的同款路径，不需要 RSD。
    if let Some(host) = lockdown_host {
        let Some(pairing) = pairing else {
            bail!(
                "lockdownd（{host}:62078）可应答，但没有配对文件：\n\
                 经典通路必须用配对记录建立会话。请在首页「输入」里选择配对文件\
                 （PC 上用 jitterbugpair / idevicepair 生成的那种）。"
            );
        };
        // 经典通路走的是 idevice 的 `install_package_with_callback`，它对**文件型**包同样是
        // `tokio::fs::read`（整个 IPA 读进内存）。大包会直接被 iOS jetsam 杀掉 App
        // ——「崩一下、没日志」最难查，所以这里主动跳过并说明。
        // （RSD / 免电脑通路不受此限：我们自己分块上传。）
        const CLASSIC_MAX_BYTES: u64 = 1500 * 1024 * 1024;
        let size = std::fs::metadata(ipa).map(|m| m.len()).unwrap_or(0);
        if size > CLASSIC_MAX_BYTES {
            let msg = format!(
                "经典通路已跳过：包约 {:.1} GB，超过该通路的内存上限\
                 （它会把整个 IPA 读进内存，大包会被系统杀掉）。请用 RSD / 免电脑通路。",
                size as f64 / 1024.0 / 1024.0 / 1024.0
            );
            log_msg(&format!("install: {msg}"));
            errors.push(format!("经典（{host}）：{msg}"));
        } else {
            log_msg(&format!(
                "install: 尝试经典通路（lockdownd {host}:62078 + 配对文件 {}）",
                pairing.display()
            ));
            match classic_install(ipa, pairing, host).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    log_msg(&format!("install: 经典通路失败：{e:#}"));
                    errors.push(format!("经典（{host}）：{e:#}"));
                }
            }
        }
    }

    // 通路是通的、最后被 iOS **策略**拒绝时（跨 App ID 覆盖升级等），这个原因才是真因：
    // 优先作为最终错误抛出，让日志尾部就是「原因 + 处理办法」。
    if hints.is_empty() {
        if let Some(hint) = explain_install_error(&errors.join("\n")) {
            hints.push(hint);
        }
    }
    if let Some(hint) = hints.first() {
        bail!("{hint}");
    }

    if errors.is_empty() {
        // 把「为什么没有通路」说到位：区分「loopback VPN 没在工作」与「VPN 在工作、但端点不对」。
        //
        // 判据（实测，见 README）：127.0.0.1:49152 是**假阳性** —— loopback VPN 的本地监听会接受
        // 连接，但一发 RSD 升级请求就被 RST（曾观察到：它「TCP 可连接」，紧接着 `Connection reset
        // by peer`；真正干活的是 VPN 对端 10.7.0.1）。所以「除 127.0.0.1 之外全不可达」就等于
        // VPN 没在工作，而不是端口/服务的问题。
        let vpn_reachable = rp_hosts.iter().any(|h| !h.is_loopback());
        let reason = if vpn_reachable {
            "候选地址能建立 TCP，但没有一个是明文 RSD，lockdownd(62078) 也都无应答"
        } else {
            "loopback VPN（StosVPN / SideStore 的描述文件）看起来**没有在工作**：\
             端口探测里只有 127.0.0.1:49152 连得上 —— 那是 VPN 本地监听的假阳性\
             （发 RSD 升级请求必被 RST），而 10.7.0.1 / 10.7.0.2 全部超时"
        };
        bail!(
            "没有找到可用的安装通路：{reason}。\n\
             处理：打开 StosVPN（或 SideStore 配套的 loopback VPN 描述文件）并让它保持连接后重试；\n\
             连上之后，本日志里会出现 `端口探测 10.7.0.1:49152 TCP 可连接`。\n\
             另：免电脑通路需要配对文件（首页「输入」→ 配对文件）。把 install: 开头的日志发出来可精确定位。"
        );
    }
    bail!("两条通路都失败：\n - {}", errors.join("\n - "));
}

/// 通路 1：RSD —— 握手拿到服务表后，用 AFC 上传到 /PublicStaging，再走 installation_proxy 安装。
async fn rsd_install(ipa: &Path, host: Ipv4Addr) -> Result<()> {
    let stream = TcpStream::connect((host, RSD_PORT))
        .await
        .with_context(|| format!("连接 RSD 失败（{host}:{RSD_PORT}）"))?;
    let mut handshake = RsdHandshake::new(stream).await.context("RSD 握手失败")?;
    log_msg(&format!(
        "install: RSD 握手成功（uuid={}，协议 v{}，服务 {} 个）",
        handshake.uuid,
        handshake.protocol_version,
        handshake.services.len()
    ));

    // 关键服务是否都在（缺失说明设备端权限/开发者模式有问题，先报出来更好定位）。
    for name in ["com.apple.afc", "com.apple.mobile.installation_proxy"] {
        let ok = handshake.services.contains_key(name);
        log_msg(&format!(
            "install: 服务 {name} {}",
            if ok { "✓" } else { "✗ 缺失" }
        ));
    }
    if !handshake.services.contains_key("com.apple.afc") {
        bail!("RSD 未提供 com.apple.afc：请确认开发者模式已开启");
    }
    if !handshake
        .services
        .contains_key("com.apple.mobile.installation_proxy")
    {
        bail!("RSD 未提供 com.apple.mobile.installation_proxy：请确认开发者模式已开启");
    }

    // 必须以 Developer 安装，否则 installd 不读内嵌描述文件，会在校验阶段拒绝。
    let mut opts = plist::Dictionary::new();
    opts.insert(
        "PackageType".to_string(),
        plist::Value::String("Developer".to_string()),
    );

    log_msg("install: 上传到 /PublicStaging 并安装（AFC + installation_proxy）…");
    let mut rsd = IpAddr::V4(host);
    install_package_with_callback_rsd(
        &mut rsd,
        &mut handshake,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| async move {
            report_percent(percent as i32);
        },
        (),
    )
    .await
    .context("安装失败（AFC 上传或 installation_proxy 安装）")?;

    Ok(())
}

/// 通路 2：经典 lockdownd —— 直连 62078 + 配对记录建立会话，
/// 之后由 `idevice` 的安装例程做「AFC 上传到 PublicStaging → installation_proxy Install」。
///
/// 注意：这里的配对文件必须是 **lockdownd 配对记录**（DeviceCertificate / HostPrivateKey …），
/// 即 jitterbugpair / idevicepair 生成的那种；RemotePairing 的配对文件格式不同。
async fn classic_install(ipa: &Path, pairing_path: &Path, host: Ipv4Addr) -> Result<()> {
    use idevice::pairing_file::PairingFile;
    use idevice::provider::TcpProvider;
    use idevice::utils::installation::install_package_with_callback;

    let pairing = PairingFile::read_from_file(pairing_path).map_err(|e| {
        anyhow::anyhow!(
            "读取配对文件失败（{}）：{e:?}\n\
             经典通路需要 lockdownd 配对记录（jitterbugpair / idevicepair 生成），\
             请确认所选文件类型正确",
            pairing_path.display()
        )
    })?;

    let provider = TcpProvider {
        addr: IpAddr::V4(host),
        scope_id: None,
        pairing_file: pairing,
        label: "SideInjector".to_string(),
    };

    let mut opts = plist::Dictionary::new();
    opts.insert(
        "PackageType".to_string(),
        plist::Value::String("Developer".to_string()),
    );

    install_package_with_callback(
        &provider,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| async move {
            report_percent(percent as i32);
        },
        (),
    )
    .await
    .map_err(|e| anyhow::anyhow!("AFC 上传 / installation_proxy 安装失败：{e:?}"))?;

    Ok(())
}

/// 统一记录进度（每跨过 5% 记一条，避免刷屏）。
/// `pub(crate)`：RP 隧道通路（rp.rs）也通过它上报百分比。
pub(crate) fn report_percent(p: i32) {
    let prev = INSTALL_PERCENT.swap(p, Ordering::Relaxed);
    if p / 5 != prev / 5 {
        log_msg(&format!("install[进度]: {p}%"));
    }
}

/// 探测 lockdownd：连接 + 发 QueryType（XML plist），有应答即认为可用。
///
/// 区分三种情况很重要：连接超时（地址/路由不对）、`Operation not permitted`（沙盒拒绝直连
/// 回环的 62078，但对 loopback VPN 的对端地址通常放行）、以及正常应答。
async fn probe_lockdown(host: Ipv4Addr) -> (bool, String) {
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const LOCKDOWN_PORT: u16 = 62078;
    const QUERY_TYPE: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Request</key><string>QueryType</string></dict></plist>"#;

    let addr = std::net::SocketAddr::from((host, LOCKDOWN_PORT));
    let mut stream =
        match tokio::time::timeout(Duration::from_millis(1500), TcpStream::connect(addr)).await {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => return (false, format!("{host}:{LOCKDOWN_PORT} 连接失败：{e}")),
            Err(_) => return (false, format!("{host}:{LOCKDOWN_PORT} 连接超时（1.5s）")),
        };
    if let Err(e) = stream.write_all(QUERY_TYPE).await {
        return (
            false,
            format!("{host}:{LOCKDOWN_PORT} 已连接，但发送 QueryType 失败：{e}"),
        );
    }
    let mut buf = vec![0u8; 512];
    match tokio::time::timeout(Duration::from_millis(1500), stream.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => {
            let text = String::from_utf8_lossy(&buf[..n]).replace(['\r', '\n'], " ");
            let head: String = text.chars().take(120).collect();
            (true, format!("{host}:{LOCKDOWN_PORT} 应答 {n} 字节：{head}"))
        }
        Ok(Ok(_)) => (false, format!("{host}:{LOCKDOWN_PORT} 已连接但应答为空")),
        Ok(Err(e)) => (false, format!("{host}:{LOCKDOWN_PORT} 读取失败：{e}")),
        Err(_) => (
            false,
            format!("{host}:{LOCKDOWN_PORT} 已连接但 1.5s 内无应答"),
        ),
    }
}


/// loopback VPN 把设备自身服务暴露出来的常见地址（回环 + StosVPN 常用的 10.7.0.x）。
fn probe_hosts() -> Vec<Ipv4Addr> {
    vec![
        Ipv4Addr::LOCALHOST,
        Ipv4Addr::new(10, 7, 0, 1),
        Ipv4Addr::new(10, 7, 0, 2),
    ]
}

/// 探测一个端点：TCP 连接 →（RSD 端口则）发送标准 RSD 升级请求 → 读响应。
///
/// 返回 `(是否像 RSD, 描述)`；描述直接进日志。判据：响应用 `HTTP/` 开头即认作 RSD
/// （remoted 会回 `HTTP/1.1 101 Switching Protocols`）。
async fn probe_endpoint(host: Ipv4Addr, port: u16, rsd_http: bool) -> (bool, String) {
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let addr = std::net::SocketAddr::from((host, port));
    let mut stream = match tokio::time::timeout(Duration::from_millis(1500), TcpStream::connect(addr)).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => return (false, format!("{host}:{port} 连接失败：{e}")),
        Err(_) => return (false, format!("{host}:{port} 连接超时（1.5s）")),
    };
    if !rsd_http {
        return (true, format!("{host}:{port} TCP 可连接"));
    }

    let req = format!(
        "GET / HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: PTTH/1.0\r\n\r\n"
    );
    if let Err(e) = stream.write_all(req.as_bytes()).await {
        return (false, format!("{host}:{port} 已连接，但发送升级请求失败：{e}"));
    }
    let mut buf = vec![0u8; 512];
    match tokio::time::timeout(Duration::from_millis(1500), stream.read(&mut buf)).await {
        Ok(Ok(0)) => (
            false,
            format!("{host}:{port} 请求后对端立即关闭（0 字节）→ 不是 RSD"),
        ),
        Ok(Ok(n)) => {
            let text = String::from_utf8_lossy(&buf[..n]).replace(['\r', '\n'], " ");
            let head: String = text.chars().take(160).collect();
            let hex: String = buf[..n.min(32)]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            let looks_rsd = text.starts_with("HTTP/");
            (
                looks_rsd,
                format!("{host}:{port} 收到 {n} 字节，响应：{head}；hex={hex}"),
            )
        }
        Ok(Err(e)) => (false, format!("{host}:{port} 请求后读取失败：{e}")),
        Err(_) => (
            false,
            format!("{host}:{port} 已连接，但 1.5s 内无响应 → 不是 RSD（疑似被中间层吞掉）"),
        ),
    }
}
