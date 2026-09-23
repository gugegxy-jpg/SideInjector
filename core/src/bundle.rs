//! 修改 .app 的 Info.plist：Bundle ID / 显示名（任意留空则不修改）。
//!
//! 仅改写 .app 根目录的 Info.plist 文件即可（系统按该文件读取 bundle 标识与名称）。
//! 支持二进制/XML plist，并保留原格式写回（iOS 的 Info.plist 多为二进制 plist）。

use crate::log_msg;
use anyhow::Result;
use plist::Value;
use std::fs;
use std::path::Path;

pub fn set_bundle_info(
    app_dir: &Path,
    bundle_id: Option<&str>,
    display_name: Option<&str>,
) -> Result<()> {
    let bundle_id = bundle_id.map(|s| s.trim()).filter(|s| !s.is_empty());
    let display_name = display_name.map(|s| s.trim()).filter(|s| !s.is_empty());
    if bundle_id.is_none() && display_name.is_none() {
        log_msg("未提供 Bundle ID / 显示名，跳过修改");
        return Ok(());
    }

    let plist_path = app_dir.join("Info.plist");
    if !plist_path.exists() {
        anyhow::bail!("未找到 Info.plist：{}", plist_path.display());
    }
    let data = fs::read(&plist_path)?;
    let is_binary = data.starts_with(b"bplist00");
    let mut value: Value = plist::from_bytes(&data)?;
    let dict = value
        .as_dictionary_mut()
        .ok_or_else(|| anyhow::anyhow!("Info.plist 顶层不是字典"))?;

    if let Some(bid) = bundle_id {
        dict.insert(
            "CFBundleIdentifier".to_string(),
            Value::String(bid.to_string()),
        );
        log_msg(&format!("设置 CFBundleIdentifier = {bid}"));
    }
    if let Some(dn) = display_name {
        dict.insert(
            "CFBundleDisplayName".to_string(),
            Value::String(dn.to_string()),
        );
        dict.insert("CFBundleName".to_string(), Value::String(dn.to_string()));
        log_msg(&format!("设置 CFBundleDisplayName/CFBundleName = {dn}"));
    }

    let mut out = Vec::new();
    if is_binary {
        plist::to_writer_binary(&mut out, &value)?;
    } else {
        plist::to_writer_xml(&mut out, &value)?;
    }
    fs::write(&plist_path, &out)?;
    log_msg("Bundle 信息已写入 Info.plist");
    Ok(())
}
