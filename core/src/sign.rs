//! 用导入的开发证书重签整个 .app bundle（进程内库签名）。
//!
//! iOS 禁止 App 通过 fork/exec 启动子进程（spawn 会报 `operation not permitted`），
//! 因此不能把 rcodesign 当外部二进制调用；这里直接链接 apple-codesign 库完成签名。

use crate::log_msg;
use anyhow::{Context, Result};
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

    log_msg(&format!(
        "sign_bundle: app={} p12={} prov={}",
        app.display(),
        p12,
        prov
    ));
    if !app.exists() {
        anyhow::bail!("待签名的 .app 不存在：{}", app.display());
    }
    diagnose_bundle(app);

    let p12_data = fs::read(p12).with_context(|| format!("读取 P12 证书失败：{p12}"))?;
    let prov_data = fs::read(prov).with_context(|| format!("读取描述文件失败：{prov}"))?;

    // p12 → 证书 + 私钥
    let (cert, key) = parse_pfx_data(&p12_data, password).context("解析 P12 证书失败（检查密码）")?;

    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, cert);
    settings.chain_apple_certificates();
    settings.set_team_id_from_signing_certificate();

    // 从 mobileprovision 提取 Entitlements 并写回签名设置
    let entitlements = extract_profile_entitlements(&prov_data)?;
    settings.set_entitlements_xml(SettingsScope::Main, entitlements.as_str())?;

    let signer = UnifiedSigner::new(settings);
    signer
        .sign_path_in_place(app)
        .with_context(|| format!("签名 .app 失败：{}", app.display()))?;

    log_msg("apple-codesign 库签名完成");
    Ok(())
}

/// 签名前诊断：apple-codesign 内部错误不带路径，这里主动把线索打出来，
/// 便于定位到底哪个文件缺失（尤其是断链的符号链接 / 主可执行 / Info.plist 位置）。
fn diagnose_bundle(app: &Path) {
    let root_plist = app.join("Info.plist");
    let contents_plist = app.join("Contents").join("Info.plist");
    log_msg(&format!(
        "bundle 诊断：根 Info.plist 存在={} / Contents/Info.plist 存在={}",
        root_plist.exists(),
        contents_plist.exists()
    ));

    let plist_path = if root_plist.exists() {
        root_plist
    } else {
        contents_plist
    };
    match fs::read(&plist_path)
        .ok()
        .and_then(|b| plist::from_bytes::<plist::Value>(&b).ok())
    {
        Some(v) => {
            let exe = v
                .as_dictionary()
                .and_then(|d| d.get("CFBundleExecutable"))
                .and_then(|x| x.as_string())
                .unwrap_or("");
            if exe.is_empty() {
                log_msg("bundle 诊断：Info.plist 无 CFBundleExecutable");
            } else {
                let exe_path = app.join(exe);
                log_msg(&format!(
                    "bundle 诊断：CFBundleExecutable={exe} 存在={}",
                    exe_path.exists()
                ));
            }
        }
        None => log_msg(&format!(
            "bundle 诊断：无法解析 Info.plist：{}",
            plist_path.display()
        )),
    }

    let mut files = 0usize;
    let mut links = 0usize;
    let mut broken: Vec<String> = Vec::new();
    walk_bundle(app, &mut files, &mut links, &mut broken);
    log_msg(&format!(
        "bundle 诊断：文件 {files}，符号链接 {links}，断链 {}",
        broken.len()
    ));
    for b in broken.iter().take(50) {
        log_msg(&format!("bundle 诊断：断链 {b}"));
    }
}

fn walk_bundle(dir: &Path, files: &mut usize, links: &mut usize, broken: &mut Vec<String>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    for e in rd.flatten() {
        let p = e.path();
        let md = match fs::symlink_metadata(&p) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let ft = md.file_type();
        if ft.is_symlink() {
            *links += 1;
            // 跟随链接看目标是否真的存在；不存在即断链（apple-codesign 会 ENOENT）。
            if fs::metadata(&p).is_err() {
                let t = fs::read_link(&p)
                    .map(|x| x.to_string_lossy().to_string())
                    .unwrap_or_default();
                broken.push(format!("{} -> {}", p.display(), t));
            }
        } else if ft.is_dir() {
            walk_bundle(&p, files, links, broken);
        } else {
            *files += 1;
        }
    }
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
