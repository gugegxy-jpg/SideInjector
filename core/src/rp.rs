//! 免电脑安装通路（RemotePairing + CDTunnel）—— iOS 17+ / 27 的正统设备端路径。
//!
//! 为什么需要它：
//!   - 设备端自连 RSD 端口发**明文**请求会被 RST：那条链路要 **TLS-PSK** 加密连接；
//!   - TLS-PSK 的密钥来自 RemotePairing 会话（`RemotePairingClient::encryption_key()`），
//!     而配对记录可以在**设备上自配对**生成（本 App 的「设备配对」卡片），所以不需要电脑。
//!
//! 完整链路（与 SideInstaller 依赖的 idevice C-FFI `tunnel_create_rppairing` 一致）：
//!   1. `RpPairingFile::read_from_file`        读自配对产出的配对记录
//!   2. `RpPairingSocket::new(stream)`         直连 RP 服务（明文 plist + b64 负载，originatedBy=host）
//!   3. `RemotePairingClient::connect`         RPPairing 握手 + pair-verify（失败则回退 pair-setup，需 PIN）
//!   4. `create_tcp_listener()`                ★ 让设备为隧道**动态开一个监听端口**
//!   5. `connect_tls_psk_tunnel_native`        连 `addr:上一步返回的端口`，用 PSK 做 TLS-PSK + CDTunnel
//!      → `tunnel.info` 给出隧道两端 IPv6 与 **RSD 端口**
//!   6. 隧道里只有裸 IPv6 包 → 用户态 TCP 栈（jktcp）在其上跑 TCP → 连 RSD 端口做握手
//!      （`idevice` 为 `AdapterHandle` 实现了 `RsdProvider`，可直接复用安装例程）
//!   7. `install_package_with_callback_rsd`    AFC 上传 /PublicStaging + installation_proxy 安装
//!
//! 代码出处（开源署名）：协议实现全部来自 `idevice` crate
//!   —— https://github.com/jkcoxson/idevice （MIT，Copyright © Jackson Coxson）。
//!   `create_tcp_listener` + 动态隧道端口这一步，参照的是该仓库 `ffi/src/tunnel_provider.rs`
//!   里 `tunnel_create_rppairing` / `finish_tunnel` 的流程（SideInstaller 亦复用同一实现）。

use crate::log_msg;
use anyhow::{bail, Context, Result};
use idevice::remote_pairing::tunnel::connect_tls_psk_tunnel_native;
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use idevice::services::rsd::RsdHandshake;
use idevice::tcp::adapter::Adapter;
use idevice::utils::installation::install_package_with_callback_rsd;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::Path;
use std::pin::Pin;
use std::task::{Context as TaskCtx, Poll};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::net::TcpStream;

/// RP 服务端口候选。设备的 RP 服务经 mDNS（`_remotepairing._tcp`）广播、端口随设备而变；
/// 设备端自连时实测 49152 可连（RP/RSD 相关服务），先用它，连不上再报错。
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

/// 第一步（诊断用）：配对验证 + 建隧道，把端点信息打进日志。
#[allow(dead_code)]
pub async fn probe(pairing_path: &Path, host: Ipv4Addr) -> Result<TunnelEndpoint> {
    let mut rpc = connect_rpc(pairing_path, host, RP_PORT).await?;
    let (tunnel_stream, _tunnel_port) = open_tunnel_stream(&mut rpc, host).await?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| anyhow::anyhow!("TLS-PSK / CDTunnel 握手失败：{e:?}"))?;
    let endpoint = endpoint_of(&tunnel.info);
    log_msg(&format!(
        "rp: 隧道已建立（{host}）—— 本端 {} / 设备侧 {} / 掩码 {} / MTU {} / RSD 端口 {}",
        endpoint.client_address,
        endpoint.server_address,
        tunnel.info.netmask,
        endpoint.mtu,
        endpoint.rsd_port
    ));
    Ok(endpoint)
}

/// 完整安装：配对验证 → 设备动态隧道端口 → TLS-PSK 隧道 → 用户态 TCP → RSD → AFC + installation_proxy。
///
/// `on_percent` 用于把 installation_proxy 回传的百分比上报给调用方（Swift 侧靠轮询取）。
pub async fn install(
    ipa: &Path,
    pairing_path: &Path,
    host: Ipv4Addr,
    on_percent: impl Fn(i32),
) -> Result<()> {
    // 1~3) RP 握手 + 配对验证（失败会回退完整 pair-setup，届时需要 PIN）
    let mut rpc = connect_rpc(pairing_path, host, RP_PORT).await?;

    // 4) 让设备为隧道动态开一个监听端口 —— 隧道**不是**建在 RP 服务端口上的
    let (tunnel_stream, tunnel_port) = open_tunnel_stream(&mut rpc, host).await?;
    log_msg(&format!("rp: 设备已为隧道开放端口 {tunnel_port}"));

    // 5) TLS-PSK + CDTunnel
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key())
        .await
        .map_err(|e| anyhow::anyhow!("TLS-PSK / CDTunnel 握手失败（隧道端口 {tunnel_port}）：{e:?}"))?;
    let endpoint = endpoint_of(&tunnel.info);
    log_msg(&format!(
        "rp: 隧道已建立 —— 本端 {} / 设备侧 {} / MTU {} / RSD 端口 {}",
        endpoint.client_address, endpoint.server_address, endpoint.mtu, endpoint.rsd_port
    ));
    if endpoint.rsd_port == 0 {
        bail!("隧道没有给出 RSD 端口（serverRSDPort=0），无法继续");
    }

    // 6) 隧道里是裸 IPv6 包 → 用户态 TCP 栈（设备端拿不到 TUN 权限，只能这么做）
    let client_addr = parse_addr(&endpoint.client_address)?;
    let server_addr = parse_addr(&endpoint.server_address)?;
    if client_addr.is_ipv4() != server_addr.is_ipv4() {
        bail!("隧道地址版本不一致：本端 {client_addr} / 设备侧 {server_addr}");
    }
    let mss = (endpoint.mtu as usize).saturating_sub(60).max(1);
    let mut adapter = Adapter::new(
        Box::new(DebugStream(tunnel.into_inner())),
        client_addr,
        server_addr,
    );
    adapter.set_mss(mss);
    let mut handle = adapter.to_async_handle();
    log_msg(&format!(
        "rp: 用户态 TCP 就绪（本端 {client_addr} → 设备侧 {server_addr}，MSS {mss}），连接 RSD 端口 {}…",
        endpoint.rsd_port
    ));

    let rsd_stream = handle
        .connect(endpoint.rsd_port)
        .await
        .map_err(|e| anyhow::anyhow!("隧道内连接 RSD 端口 {} 失败：{e:?}", endpoint.rsd_port))?;
    let mut handshake = RsdHandshake::new(rsd_stream)
        .await
        .context("RSD 握手失败（经 RP 隧道）")?;
    log_msg(&format!(
        "rp: RSD 握手成功（uuid={}，协议 v{}，服务 {} 个）",
        handshake.uuid,
        handshake.protocol_version,
        handshake.services.len()
    ));
    // 先把这条隧道到底是什么打出来：RSD 的 uuid / properties / 全部服务名。
    // iOS 上 `create_tcp_listener` 可能给出「受信」或「未受信」两类隧道，
    // 未受信隧道只暴露一小撮服务（通常不含 AFC / installation_proxy）。
    let mut props: Vec<String> = handshake.properties.keys().cloned().collect();
    props.sort();
    log_msg(&format!(
        "rp: RSD uuid={}，协议 v{}，properties：{}",
        handshake.uuid,
        handshake.protocol_version,
        props.join("、")
    ));
    let mut names: Vec<String> = handshake.services.keys().cloned().collect();
    names.sort();
    log_msg(&format!("rp: RSD 服务共 {} 个：", names.len()));
    for chunk in names.chunks(6) {
        log_msg(&format!("rp:   {}", chunk.join("、")));
    }
    // 逐个打印解析结果（port / entitlement 摘要）：可看出端口是否为 0、条目是否可疑。
    for name in &names {
        if let Some(svc) = handshake.services.get(name) {
            log_msg(&format!(
                "rp: 服务明细 {name} port={} remote_xpc={} entitlement={}",
                svc.port,
                svc.uses_remote_xpc,
                if svc.entitlement.is_empty() {
                    "(空)"
                } else {
                    svc.entitlement.as_str()
                }
            ));
        }
    }
    let tunnel_svcs: Vec<&str> = names
        .iter()
        .map(|s| s.as_str())
        .filter(|n| n.contains("tunnelservice"))
        .collect();
    log_msg(&format!(
        "rp: 隧道服务条目（判断受信/未受信）：{}",
        if tunnel_svcs.is_empty() {
            "无".to_string()
        } else {
            tunnel_svcs.join("、")
        }
    ));

    // ★ 关键：这条隧道暴露的是 RSD 的「remote 命名」——服务名统一带 `.shim.remote` 后缀，
    // 例如 com.apple.afc.shim.remote / com.apple.mobile.installation_proxy.shim.remote。
    // 而 idevice 的安装例程是按**固定名**（com.apple.afc / com.apple.mobile.installation_proxy）
    // 去查服务表的，查不到就报「缺失」。这里给缺的名字补上别名（指向同一个服务、同一端口），
    // 两边就对上了——隧道本身是好的，不用重建。
    for (canonical, remote) in [
        ("com.apple.afc", "com.apple.afc.shim.remote"),
        (
            "com.apple.mobile.installation_proxy",
            "com.apple.mobile.installation_proxy.shim.remote",
        ),
        (
            "com.apple.mobile.house_arrest",
            "com.apple.mobile.house_arrest.shim.remote",
        ),
    ] {
        if handshake.services.contains_key(canonical) {
            continue;
        }
        if let Some(svc) = handshake.services.get(remote).cloned() {
            log_msg(&format!(
                "rp: 服务别名 {canonical} ← {remote}（port {}）",
                svc.port
            ));
            handshake.services.insert(canonical.to_string(), svc);
        }
    }

    for name in ["com.apple.afc", "com.apple.mobile.installation_proxy"] {
        log_msg(&format!(
            "rp: 服务 {name} {}",
            if handshake.services.contains_key(name) {
                "✓"
            } else {
                "✗ 缺失"
            }
        ));
    }
    if !handshake.services.contains_key("com.apple.afc") {
        bail!(
            "RSD 未提供 com.apple.afc（连 .shim.remote 变体也没有；本隧道共 {} 个服务）",
            names.len()
        );
    }
    if !handshake
        .services
        .contains_key("com.apple.mobile.installation_proxy")
    {
        bail!(
            "RSD 未提供 com.apple.mobile.installation_proxy（连 .shim.remote 变体也没有；本隧道共 {} 个服务）",
            names.len()
        );
    }

    // 7) 必须以 Developer 安装，否则 installd 不读内嵌描述文件，会在校验阶段拒绝。
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

/// 已建立的 RP 客户端（host 角色，直连原始 TCP）。
type Rpc = RemotePairingClient<RpPairingSocket<TcpStream>>;

/// 连上设备的 RP 服务：RPPairing 握手 + 配对验证（验证失败会自动回退完整 pair-setup）。
async fn connect_rpc(pairing_path: &Path, host: Ipv4Addr, port: u16) -> Result<Rpc> {
    let mut pairing = load_pairing(pairing_path).await?;
    let stream = TcpStream::connect((host, port))
        .await
        .with_context(|| format!("连接 RP 服务失败（{host}:{port}）"))?;

    // 直连 RP 服务必须用 `RpPairingSocket`（明文 plist + b64 负载、originatedBy="host"）；
    // `RemoteXpcClient` 是「经 RemoteXPC 通道访问 RP」用的（raw bytes），
    // 用它直连原始 TCP 会被设备当成非法帧直接 RST（实测 code 54）。
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "SideInjector");

    // 若设备要求确认（pair-setup 回退），PIN 由我们这侧给出、在设备上输入；
    // 正常情况下已有配对记录，pair-verify 直接通过，用不到 PIN。
    let pin = pseudo_pin();
    log_msg(&format!(
        "rp: 开始配对验证（若设备提示输入 PIN，请输入 {pin}）"
    ));
    rpc.connect(&mut pairing, || {
        let p = pin.clone();
        async move { p }
    })
    .await
    .map_err(|e| {
        anyhow::anyhow!("RPPairing 握手 / 配对验证失败（{host}:{port}）：{e:?}")
    })?;
    log_msg("rp: 配对验证通过");
    Ok(rpc)
}

/// 让设备为隧道开放端口，并连上它（TLS-PSK 之前的裸 TCP 流）。
async fn open_tunnel_stream(rpc: &mut Rpc, host: Ipv4Addr) -> Result<(TcpStream, u16)> {
    let port = rpc
        .create_tcp_listener()
        .await
        .map_err(|e| anyhow::anyhow!("请求设备创建隧道监听端口失败：{e:?}"))?;
    if port == 0 {
        bail!("设备返回的隧道端口为 0");
    }
    let stream = TcpStream::connect(SocketAddr::from((host, port)))
        .await
        .with_context(|| format!("连接隧道端口失败（{host}:{port}）"))?;
    Ok((stream, port))
}

/// 读取 RemotePairing 配对记录。
async fn load_pairing(pairing_path: &Path) -> Result<RpPairingFile> {
    let pairing = RpPairingFile::read_from_file(pairing_path).await.map_err(|e| {
        anyhow::anyhow!(
            "读取 RemotePairing 配对文件失败（{}）：{e:?}\n\
             该通路需要「设备配对」卡片自配对产出的配对记录，\
             不是 jitterbugpair / idevicepair 生成的 lockdownd 配对文件",
            pairing_path.display()
        )
    })?;
    log_msg("rp: 已加载 RemotePairing 配对文件");
    Ok(pairing)
}

/// 从隧道信息里取我们要的字段（避免在代码里写出其类型名）。
fn endpoint_of(info: &idevice::tunnel::TunnelInfo) -> TunnelEndpoint {
    TunnelEndpoint {
        client_address: info.client_address.clone(),
        server_address: info.server_address.clone(),
        mtu: info.mtu,
        rsd_port: info.server_rsd_port,
    }
}

/// 隧道返回的地址可能带 `/128` 之类后缀，这里只取地址部分。
fn parse_addr(s: &str) -> Result<IpAddr> {
    let cleaned = s.split('/').next().unwrap_or(s).trim();
    cleaned
        .parse::<IpAddr>()
        .map_err(|e| anyhow::anyhow!("隧道地址解析失败（{s}）：{e}"))
}

/// 6 位 PIN（时间派生，仅用于 pair-setup 回退时的设备端确认，不涉及密钥）。
fn pseudo_pin() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("{:06}", (nanos as u32) % 1_000_000)
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
