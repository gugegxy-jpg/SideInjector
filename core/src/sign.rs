//! 用导入的开发证书重签整个 .app bundle。
//!
//! 方案优先级：
//!   A. 若设了环境变量 `RCODESIGN_PATH` 指向打包进 App 的 `rcodesign` iOS 二进制，
//!      直接命令行调用（最稳，apple-codesign 的 CLI 路径）。
//!   B. 否则尝试纯 Rust 库签名（apple-codesign），见下方 TODO。

use crate::log_msg;
use anyhow::{bail, Result};
use std::path::Path;
use std::process::Command;

pub fn sign_bundle(
    app: &Path,
    p12: Option<&str>,
    password: &str,
    prov: Option<&str>,
    _team: Option<&str>,
) -> Result<()> {
    if let Ok(rc) = std::env::var("RCODESIGN_PATH") {
        if !rc.is_empty() {
            return sign_with_rcodesign(app, &rc, p12, password, prov);
        }
    }
    sign_with_library(app, p12, password, prov)
}

fn sign_with_rcodesign(
    app: &Path,
    rc: &str,
    p12: Option<&str>,
    password: &str,
    prov: Option<&str>,
) -> Result<()> {
    let p12 = p12.ok_or_else(|| anyhow::anyhow!("缺少 p12 证书路径"))?;
    let prov = prov.ok_or_else(|| anyhow::anyhow!("缺少 mobileprovision 描述文件"))?;

    let mut cmd = Command::new(rc);
    cmd.arg("sign")
        .arg("--p12-file")
        .arg(p12)
        .arg("--p12-password")
        .arg(password)
        .arg("--profile")
        .arg(prov)
        .arg(app);
    log_msg(&format!("执行: {cmd:?}"));
    let out = cmd.output()?;
    if !out.status.success() {
        bail!("rcodesign 失败: {}", String::from_utf8_lossy(&out.stderr));
    }
    log_msg("rcodesign 签名完成");
    Ok(())
}

/// TODO：纯 Rust 库签名。需启用 Cargo.toml 中 `apple-codesign` 依赖，并对照所装版本 API：
///   use apple_codesign::{BundleSigner, ...};
///   let mut signer = BundleSigner::new();
///   signer.load_certificate_chain_pem(...)?;
///   signer.load_signing_key_pem(...)?;
///   signer.sign_bundle_path(app, app)?;
fn sign_with_library(
    _app: &Path,
    _p12: Option<&str>,
    _password: &str,
    _prov: Option<&str>,
) -> Result<()> {
    bail!("未配置签名后端：请把编译好的 rcodesign(iOS) 放进 App，并设置环境变量 RCODESIGN_PATH")
}
