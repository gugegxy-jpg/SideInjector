//! 免电脑安装通路（RemotePairing + CDTunnel）—— iOS 17+ / 27 的正统设备端路径。
//!
//! 为什么需要它：
//!   - 设备端自连 RSD 端口（49152）发**明文** HTTP 升级请求会被 RST：那个端口上的
//!     `remoted` / RP 服务要的是 **TLS-PSK** 加密连接；
//!   - TLS-PSK 的密钥来自 RemotePairing 会话（`RemotePairingClient::encryption_key()`），
//!     而配对记录可以**在设备上自配对生成**（本 App 的「设备配对」卡片），所以不需要电脑。
//!
//! 完整链路：
//!   1. `RpPairingFile::read_from_file`           读自配对产出的配对记录（不是 lockdownd 那种）
//!   2. `RemotePairingClient::validate_pairing`   与设备 RP 服务验证（已有记录 → 不需要 PIN）
//!   3. `client.encryption_key()`                 取 TLS-PSK
//!   4. `connect_tls_psk_tunnel_native(stream, psk)`  TLS-PSK + CDTunnel → `CdTunnel`，
//!      其 `info` 给出设备侧 IPv6 与**RSD 端口**（不必猜 49152）
//!   5. 隧道里只有裸 IPv6 包，用内置的**用户态 TCP 栈**（jktcp）在其上跑 TCP，
//!      连上 RSD 端口做握手 —— `idevice` 为 `AdapterHandle` 实现了 `RsdProvider`，
//!      因此可以直接复用 `install_package_with_callback_rsd`（AFC 上传 + installation_proxy）
//!
//! 代码出处（开源署名）：协议实现全部来自 `idevice` crate
//!   —— https://github.com/jkcoxson/idevice （MIT，Copyright © Jackson Coxson）。

use crate::log_msg;
use anyhow::{bail, Context, Result};
use idevice::remote_pairing::tunnel::connect_tls_psk_tunnel_native;
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile};
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::utils::installation::install_package_with_callback_rsd;
use idevice::RemoteXpcClient;
use std::io;
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;
use std::pin::Pin;
use std::task::{Context as TaskCtx, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

/// 设备端 RP / RSD 服务端口（同一个端口：明文连上会被直接拒，必须 TLS-PSK）。
pub const RP_PORT: u16 = 49152;

/// 隧道端点信息（从 CDTunnel 握手结果里摘出来的我们需要的部分）。
#[derive(Debug, Clone)]
pub struct TunnelEndpoint {
    /// 隧道本端（我们这侧）的 IPv6 地址。
    pub client_address: String,
    /// 隧道设备侧的 IPv6 地址（RSD 服务在它上面）。
    pub server_address: String,
    /// 协商的 MTU。
    pub mtu: u16,
    /// 设备上的 RSD 端口（经隧道访问）。
    pub rsd_port: u16,
}

/// 第一步（诊断用）：只用配对记录验证身份并建立 CDTunnel，把端点信息打进日志。
pub async fn probe(pairing_path: &Path, host: Ipv4Addr) -> Result<TunnelEndpoint> {
    let psk = validate(pairing_path, host).await?;
    let info = open_tunnel(host, &psk).await?;
    Ok(info)
}

/// 完整安装：验证配对记录 → TLS-PSK 隧道 → 用户态 TCP → RSD 握手 → AFC + installation_proxy。
///
/// `on_percent` 用于把 installation_proxy 回传的百分比上报给调用方（Swift 侧靠轮询取）。
pub async fn install(
    ipa: &Path,
    pairing_path: &Path,
    host: Ipv4Addr,
    on_percent: impl Fn(i32),
) -> Result<()> {
    let psk = validate(pairing_path, host).await?;

    // TLS-PSK + CDTunnel：隧道只建一次，信息与本体都从这里拿。
    let stream = TcpStream::connect((host, RP_PORT))
        .await
        .with_context(|| format!("连接 RP 服务失败（{host}:{RP_PORT}）"))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, &psk)
        .await
        .map_err(|e| anyhow::anyhow!("TLS-PSK / CDTunnel 握手失败（{host}:{RP_PORT}）：{e:?}"))?;

    let client_address = tunnel.info.client_address.clone();
    let server_address = tunnel.info.server_address.clone();
    let netmask = tunnel.info.netmask.clone();
    let mtu = tunnel.info.mtu;
    let rsd_port = tunnel.info.server_rsd_port;
    log_msg(&format!(
        "rp: 隧道已建立（{host}）—— 本端 {client_address} / 设备侧 {server_address} \
         / 掩码 {netmask} / MTU {mtu} / RSD 端口 {rsd_port}"
    ));
    if rsd_port == 0 {
        bail!("隧道没有给出 RSD 端口（serverRSDPort=0），无法继续");
    }

    let client_addr = parse_addr(&client_address)?;
    let server_addr = parse_addr(&server_address)?;
    if client_addr.is_ipv4() != server_addr.is_ipv4() {
        bail!("隧道地址版本不一致：本端 {client_addr} / 设备侧 {server_addr}");
    }

    // 隧道里是裸 IPv6 包，交给用户态 TCP 栈（jktcp）：它自己按 IP 头长度切分报文，
    // 所以这里直接把字节流交给它即可（设备端拿不到 TUN 权限，只能这么做）。
    let mtu_usize = mtu as usize;
    // MSS = MTU - 40(IPv6 头) - 20(TCP 头)
    let mss = mtu_usize.saturating_sub(60).max(1);
    let mut adapter = Adapter::new(
        Box::new(DebugStream(tunnel.into_inner())),
        client_addr,
        server_addr,
    );
    adapter.set_mss(mss);
    let mut handle = adapter.to_async_handle();
    log_msg(&format!(
        "rp: 用户态 TCP 就绪（本端 {client_addr} → 设备侧 {server_addr}，MSS {mss}），连接 RSD 端口 {rsd_port}…"
    ));

    // 经隧道与设备的 RSD 服务握手（拿服务表），再复用安装例程。
    let stream = handle
        .connect(rsd_port)
        .await
        .map_err(|e| anyhow::anyhow!("隧道内连接 RSD 端口 {rsd_port} 失败：{e:?}"))?;
    let mut handshake = RsdHandshake::new(stream)
        .await
        .context("RSD 握手失败（经 RP 隧道）")?;
    log_msg(&format!(
        "rp: RSD 握手成功（uuid={}，协议 v{}，服务 {} 个）",
        handshake.uuid,
        handshake.protocol_version,
        handshake.services.len()
    ));
    for name in ["com.apple.afc", "com.apple.mobile.installation_proxy"] {
        log_msg(&format!(
            "rp: 服务 {name} {}",
            if handshake.services.contains_key(name) { "✓" } else { "✗ 缺失" }
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

    log_msg("rp: 上传到 /PublicStaging 并安装（AFC + installation_proxy，经隧道）…");
    install_package_with_callback_rsd(
        &mut handle,
        &mut handshake,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| {
            on_percent(percent as i32);
            std::future::ready(())
        },
        (),
    )
    .await
    .map_err(|e| anyhow::anyhow!("经隧道的安装失败（AFC 上传 / installation_proxy）：{e:?}"))?;

    Ok(())
}

// MARK: - 内部步骤

/// 用配对记录向设备 RP 服务验证身份，返回 TLS-PSK 密钥。
async fn validate(pairing_path: &Path, host: Ipv4Addr) -> Result<Vec<u8>> {
    let mut pairing = RpPairingFile::read_from_file(pairing_path).await.map_err(|e| {
        anyhow::anyhow!(
            "读取 RemotePairing 配对文件失败（{}）：{e:?}\n\
             该通路需要「设备配对」卡片自配对产出的配对记录，\
             不是 jitterbugpair / idevicepair 生成的 lockdownd 配对文件",
            pairing_path.display()
        )
    })?;
    log_msg("rp: 已加载 RemotePairing 配对文件");

    let stream = TcpStream::connect((host, RP_PORT))
        .await
        .with_context(|| format!("连接 RP 服务失败（{host}:{RP_PORT}）"))?;
    let xpc = RemoteXpcClient::new(stream)
        .await
        .map_err(|e| anyhow::anyhow!("创建 RP 客户端失败：{e:?}"))?;
    let mut client = RemotePairingClient::new(xpc, "SideInjector");
    client
        .validate_pairing(&mut pairing)
        .await
        .map_err(|e| anyhow::anyhow!("配对记录验证失败（{host}:{RP_PORT}）：{e:?}"))?;
    log_msg("rp: 配对记录验证通过");
    Ok(client.encryption_key().to_vec())
}

/// TLS-PSK + CDTunnel 握手，返回隧道端点信息。
async fn open_tunnel(host: Ipv4Addr, psk: &[u8]) -> Result<TunnelEndpoint> {
    let stream = TcpStream::connect((host, RP_PORT))
        .await
        .with_context(|| format!("连接 RP 服务失败（{host}:{RP_PORT}）"))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, psk)
        .await
        .map_err(|e| anyhow::anyhow!("TLS-PSK / CDTunnel 握手失败（{host}:{RP_PORT}）：{e:?}"))?;
    let info = &tunnel.info;
    let endpoint = TunnelEndpoint {
        client_address: info.client_address.clone(),
        server_address: info.server_address.clone(),
        mtu: info.mtu,
        rsd_port: info.server_rsd_port,
    };
    log_msg(&format!(
        "rp: 隧道已建立（{host}）—— 本端 {} / 设备侧 {} / 掩码 {} / MTU {} / RSD 端口 {}",
        endpoint.client_address,
        endpoint.server_address,
        info.netmask,
        endpoint.mtu,
        endpoint.rsd_port
    ));
    Ok(endpoint)
}

/// 隧道返回的地址可能带 `/128` 之类后缀，这里只取地址部分。
fn parse_addr(s: &str) -> Result<IpAddr> {
    let cleaned = s.split('/').next().unwrap_or(s).trim();
    cleaned
        .parse::<IpAddr>()
        .map_err(|e| anyhow::anyhow!("隧道地址解析失败（{s}）：{e}"))
}

// MARK: - 传输包装

/// 透明包装：为底层流补上 `Debug`（用户态 TCP 栈的传输要求），其余语义原样转发。
struct DebugStream<S>(S);

impl<S> std::fmt::Debug for DebugStream<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TunnelStream")
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for DebugStream<S> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut TaskCtx<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for DebugStream<S> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut TaskCtx<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().0).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut TaskCtx<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut TaskCtx<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().0).poll_shutdown(cx)
    }
}
