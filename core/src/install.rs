//! 设备端安装 —— 走 CoreDevice / RSD 路径（iOS 17+ 的本机安装通道）。
//!
//! 为什么不是经典 lockdownd：
//!   实测（App 内端口探测）在设备自身只能连上 **RSD 49152**，而 lockdownd 62078 /
//!   usbmuxd 27015 在 127.0.0.1、VPN 地址（10.7.0.0）、WiFi 地址上全部超时。
//!   也就是说 iOS 17+ 的设备端安装只有 RSD 这一条路。
//!
//! 链路（全部用 `idevice` crate，MIT 许可；不涉及任何非商业代码）：
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
    let stream = TcpStream::connect((Ipv4Addr::LOCALHOST, RSD_PORT))
        .await
        .with_context(|| format!("连接 RSD 失败（127.0.0.1:{RSD_PORT}）"))?;
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
    let mut rsd = IpAddr::V4(Ipv4Addr::LOCALHOST);
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
