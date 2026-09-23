//! 免电脑安装通路（RemotePairing + CDTunnel）—— iOS 17+ / 27 的正统设备端路径。
//!
//! 为什么需要它：
//!   - 设备端自连 RSD 端口（49152）发**明文** HTTP 升级请求会被 RST：那个端口上的
//!     `remoted` / RP 服务要的是 **TLS-PSK** 加密连接；
//!   - TLS-PSK 的密钥来自 RemotePairing 会话（`RemotePairingClient::encryption_key()`），
//!     而配对记录可以**在设备上自配对生成**（本 App 的「设备配对」卡片），所以不需要电脑。
//!
//! 链路：
//!   1. `RpPairingFile::read_from_file`     读自配对产出的配对记录（不是 lockdownd 那种）
//!   2. `RemotePairingClient::validate_pairing`  与设备 RP 服务验证（已有记录 → 不需要 PIN）
//!   3. `client.encryption_key()`           取 TLS-PSK
//!   4. `connect_tls_psk_tunnel_native(stream, psk)`  TLS-PSK + CDTunnel 握手 → `CdTunnel`；
//!      其 `info` 直接给出**设备侧 IPv6 地址**与 **RSD 端口**（不必猜 49152）
//!   5. 隧道之上用用户态 TCP（`jktcp`，无需 TUN 权限）连 RSD 服务，
//!      再复用安装模块的 AFC + installation_proxy 流程
//!
//! 代码出处（开源署名）：协议实现全部来自 `idevice` crate
//!   —— https://github.com/jkcoxson/idevice （MIT，Copyright © Jackson Coxson）。

use crate::log_msg;
use anyhow::{Context, Result};
use idevice::remote_pairing::tunnel::connect_tls_psk_tunnel_native;
use idevice::remote_pairing::{RemotePairingClient, RpPairingFile};
use idevice::RemoteXpcClient;
use std::net::Ipv4Addr;
use std::path::Path;
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

/// 第一步：用配对记录验证身份并建立 CDTunnel，返回隧道端点。
///
/// 成功即证明「免电脑」链路成立；失败会带出确切原因
/// （配对文件格式不对 / 验证失败 / 端口上不是 RP 服务）。
pub async fn probe(pairing_path: &Path, host: Ipv4Addr) -> Result<TunnelEndpoint> {
    let mut pairing = RpPairingFile::read_from_file(pairing_path).await.map_err(|e| {
        anyhow::anyhow!(
            "读取 RemotePairing 配对文件失败（{}）：{e:?}\n\
             该通路需要「设备配对」卡片自配对产出的配对记录，\
             不是 jitterbugpair / idevicepair 生成的 lockdownd 配对文件",
            pairing_path.display()
        )
    })?;
    log_msg("rp: 已加载 RemotePairing 配对文件");

    // 1) 与设备 RP 服务验证配对记录（用已有记录 → 不需要 PIN）
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
    let psk = client.encryption_key().to_vec();
    log_msg(&format!(
        "rp: 配对记录验证通过，已取得 TLS-PSK（{} 字节）",
        psk.len()
    ));

    // 2) 另起一条连接：TLS-PSK + CDTunnel 握手，拿到隧道
    let stream = TcpStream::connect((host, RP_PORT))
        .await
        .with_context(|| format!("连接 RP 服务失败（{host}:{RP_PORT}）"))?;
    let tunnel = connect_tls_psk_tunnel_native(stream, &psk)
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
