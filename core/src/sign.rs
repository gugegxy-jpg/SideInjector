//! 用导入的开发证书重签整个 .app bundle（进程内库签名）。
//!
//! iOS 禁止 App 通过 fork/exec 启动子进程（spawn 会报 `operation not permitted`），
//! 因此不能把 rcodesign 当外部二进制调用；这里直接链接 apple-codesign 库完成签名。

use crate::log_msg;
use anyhow::Result;
use apple_codesign::cryptography::parse_pfx_data;
use apple_codesign::{SettingsScope, SigningSettings, UnifiedSigner};
use std::fs;
use std::path::Path;

pub fn sign_bundle(
    app: &Path,
    p12: Option<&str>,
    password: &str,
    prov: Option<&str>,
    _team: Option<&str>,
) -> Result<()> {
    let p12 = p12.ok_or_else(|| anyhow::anyhow!("缺少 p12 证书路径"))?;
    let prov = prov.ok_or_else(|| anyhow::anyhow!("缺少 mobileprovision 描述文件"))?;

    let p12_data = fs::read(p12)?;
    let prov_data = fs::read(prov)?;

    // p12 → 证书 + 私钥
    let (cert, key) = parse_pfx_data(&p12_data, password)?;

    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, cert);
    settings.chain_apple_certificates();
    settings.set_team_id_from_signing_certificate();

    // 从 mobileprovision 提取 Entitlements 并写回签名设置
    let entitlements = extract_profile_entitlements(&prov_data)?;
    settings.set_entitlements_xml(SettingsScope::Main, entitlements.as_str())?;

    let signer = UnifiedSigner::new(settings);
    signer.sign_path_in_place(app)?;

    log_msg("apple-codesign 库签名完成");
    Ok(())
}

/// 从 .mobileprovision（CMS/DER 包裹的 XML plist）提取 Entitlements 字典，
/// 并序列化为完整 plist XML 供 `set_entitlements_xml` 使用。
fn extract_profile_entitlements(data: &[u8]) -> Result<String> {
    let plist = extract_embedded_plist(data)?;
    let value: plist::Value = plist::from_bytes(&plist)?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 顶层不是字典"))?;
    let ents = dict
        .get("Entitlements")
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 缺少 Entitlements"))?;
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, ents)?;
    Ok(String::from_utf8(out)?)
}

/// 在 DER 编码的 mobileprovision 中定位连续存放的 XML plist 字节。
fn extract_embedded_plist(data: &[u8]) -> Result<Vec<u8>> {
    let start_marker: &[u8] = b"<?xml";
    let end_marker: &[u8] = b"</plist>";
    let start = data
        .windows(start_marker.len())
        .position(|w| w == start_marker)
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 中未找到 plist"))?;
    let rest = &data[start..];
    let end = rest
        .windows(end_marker.len())
        .position(|w| w == end_marker)
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 中 plist 未闭合"))?;
    Ok(data[start..start + end + end_marker.len()].to_vec())
}
