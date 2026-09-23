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
pub fn install_ipa(ipa: &Path) -> Result<()> {
    if !ipa.exists() {
        bail!("待安装的 IPA 不存在：{}", ipa.display());
    }
    set_percent(0);
    log_msg(&format!("install: 连接本机 RSD 127.0.0.1:{RSD_PORT}"));

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .context("创建 tokio 运行时失败")?;

    let ipa = ipa.to_path_buf();
    let result = rt.block_on(async move { install_async(&ipa).await });
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

async fn install_async(ipa: &Path) -> Result<()> {
    // 先做原始探测再握手。原因：`RsdHandshake` 内部第一步就是 HTTP 升级，
    // 一旦对端不是 remoted（例如 loopback VPN 只转发特定端口、或那个端口不是 RSD），
    // 只会得到一句 "Connection reset by peer"，看不出对端到底是什么。
    // 这里直接发标准升级请求并打印真实响应，同时多试几个 loopback VPN 常用地址。
    let mut rsd_host = Ipv4Addr::LOCALHOST;
    let mut rsd_ok = false;
    let mut notes: Vec<String> = Vec::new();
    for host in probe_hosts() {
        let (ok, note) = probe_endpoint(host, RSD_PORT, true).await;
        log_msg(&format!("install: RSD 探测 {note}"));
        notes.push(note);
        if ok && !rsd_ok {
            rsd_host = host;
            rsd_ok = true;
        }
    }
    // 经典通路顺手探一下（只探回环），用于判断「该走哪条协议」而不是反复试错。
    for port in [62078u16, 27015u16] {
        let (_, note) = probe_endpoint(Ipv4Addr::LOCALHOST, port, false).await;
        log_msg(&format!("install: 端口探测 {note}"));
    }
    if !rsd_ok {
        bail!(
            "本机找不到可用的 RSD 端点（49152）。\n\
             探测结果：{}\n\
             若 49152 能连上但对升级请求不应答/直接断开，说明它不是 remoted \
             （常见于 loopback VPN 只转发特定端口）。请把上面 install: 开头的几行日志发出来，\
             并确认 loopback VPN（StosVPN / SideStore 描述文件）已开启。",
            notes.join("；")
        );
    }
    log_msg(&format!("install: 使用 RSD 端点 {rsd_host}:{RSD_PORT}"));

    let stream = TcpStream::connect((rsd_host, RSD_PORT))
        .await
        .with_context(|| format!("连接 RSD 失败（{rsd_host}:{RSD_PORT}）"))?;
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
    let mut rsd = IpAddr::V4(rsd_host);
    install_package_with_callback_rsd(
        &mut rsd,
        &mut handshake,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| async move {
            let p = percent as i32;
            let prev = INSTALL_PERCENT.swap(p, Ordering::Relaxed);
            // 每跨过 5% 记一条，避免刷屏。
            if p / 5 != prev / 5 {
                log_msg(&format!("install[进度]: {p}%"));
            }
        },
        (),
    )
    .await
    .context("安装失败（AFC 上传或 installation_proxy 安装）")?;

    Ok(())
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
