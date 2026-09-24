//! 修改 .app 的 Info.plist：Bundle ID / 显示名（任意留空则不修改）。
//!
//! 主 App 的标识与名称写在 .app 根目录的 Info.plist 里；嵌套扩展自己的标识写在各自的
//! Info.plist 里。支持二进制/XML plist，并保留原格式写回（iOS 的 Info.plist 多为二进制 plist）。
//!
//! **改 Bundle ID 时必须连带改嵌套扩展**（见 `rewrite_extension_ids`）：iOS 在安装期强制要求
//! 「扩展的 Bundle ID 以父 App 的 Bundle ID 为前缀」，只改主 App 会让 installd 以
//! `Mismatched bundle IDs` 拒绝（实测：637 MB 的包上传完才被拒）。
//!
//! 另外，**改版 IPA 本身可能就是坏的**：第三方打包时把主 App 的 bundle id 改了、却没改扩展
//! （实测：抖音助手把主 App 改成 `com.douyin.xyz`，`PlugIns/DYShareExtension.appex` 仍是
//! `com.ss.iphone.ugc.Aweme.DYShareExtension`），用户什么都不改、原样签名也会装不上。
//! 所以签名前还有一次**无条件自愈**：`normalize_extension_ids`。

use crate::log_msg;
use anyhow::Result;
use plist::Value;
use std::fs;
use std::path::{Path, PathBuf};

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

    // 先记住旧的主 Bundle ID：嵌套扩展的新标识要用它的「后缀」拼出来。
    let old_main_id = dict
        .get("CFBundleIdentifier")
        .and_then(|v| v.as_string())
        .map(str::to_string);

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

    // 主 App 改了 Bundle ID → 同步改写嵌套扩展（.appex / Watch App）的 Bundle ID。
    if let (Some(new_id), Some(old_id)) = (bundle_id, old_main_id.as_deref()) {
        if new_id != old_id {
            let n = rewrite_extension_ids(app_dir, old_id, new_id);
            log_msg(&format!("嵌套扩展 Bundle ID 同步：共改写 {n} 个"));
        }
    }
    Ok(())
}

/// 自愈：把**所有嵌套扩展**的 Bundle ID 都改成以主 App 当前的 Bundle ID 为前缀。
///
/// 为什么签名阶段也要无条件做一次：第三方改版 IPA 常见「主 App 的 bundle id 被改过、
/// 嵌套扩展没跟着改」。这种包**什么都不改、原样签名**也会被 installd 拒绝：
/// `APIInternalError … IXErrorDomain Code=8 "… does not match required prefix of <父 id>. for parent"`
/// （`NSLocalizedFailureReason=Mismatched bundle IDs.`）。
///
/// 返回改写的个数（本来就正确的扩展不计入）。
pub fn normalize_extension_ids(app_dir: &Path) -> usize {
    let Some(main_id) = read_bundle_id(&app_dir.join("Info.plist")) else {
        return 0;
    };
    // 旧的主 ID 未知（不是我们改的）→ 后缀退回「最后一个点号之后」，同样满足前缀要求。
    rewrite_extension_ids(app_dir, "", &main_id)
}

/// 读一个 Info.plist 的 `CFBundleIdentifier`。
fn read_bundle_id(plist_path: &Path) -> Option<String> {
    let data = fs::read(plist_path).ok()?;
    let value: Value = plist::from_bytes(&data).ok()?;
    value
        .as_dictionary()?
        .get("CFBundleIdentifier")?
        .as_string()
        .map(str::to_string)
}

/// 把嵌套扩展（含 Watch App）的 Bundle ID 改写成 `new_main.后缀`。
///
/// 只处理 Info.plist 里含 `NSExtension`（扩展）或 `WKWatchKitApp`（Watch App）的嵌套 bundle；
/// `.framework` / 资源 `.bundle` 的标识是独立的，前缀规则不适用，**不能**改。
///
/// `old_main` 为空表示「旧的主 ID 未知」（自愈路径），此时后缀取扩展 ID 最后一个点号之后；
/// 非空时用 `old_main` 前缀剥出精确后缀。返回改写的个数。
fn rewrite_extension_ids(app_dir: &Path, old_main: &str, new_main: &str) -> usize {
    // 收集所有嵌套的 Info.plist（跳过主 App 根目录那一个）。
    let main_plist = app_dir.join("Info.plist");
    let mut plists: Vec<PathBuf> = Vec::new();
    let mut stack: Vec<PathBuf> = vec![app_dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            let path = entry.path();
            let Ok(md) = fs::symlink_metadata(&path) else {
                continue;
            };
            if md.file_type().is_symlink() {
                continue;
            }
            if md.is_dir() {
                stack.push(path);
            } else if entry.file_name() == "Info.plist" && path != main_plist {
                plists.push(path);
            }
        }
    }

    let prefix = format!("{new_main}.");
    let mut changed = 0usize;
    for p in plists {
        let Ok(data) = fs::read(&p) else { continue };
        let is_binary = data.starts_with(b"bplist00");
        let Ok(mut value) = plist::from_bytes::<Value>(&data) else {
            continue;
        };
        let Some(d) = value.as_dictionary_mut() else {
            continue;
        };
        // 只处理扩展 / Watch App；framework 与资源 bundle 不改。
        if d.get("NSExtension").is_none() && d.get("WKWatchKitApp").is_none() {
            continue;
        }
        let Some(old_id) = d
            .get("CFBundleIdentifier")
            .and_then(|v| v.as_string())
            .map(str::to_string)
        else {
            continue;
        };
        // 已经满足前缀要求 → 不动（幂等：重复签名不会反复改写）。
        if old_id.starts_with(&prefix) {
            continue;
        }
        // 后缀：知道旧主 ID 就精确剥；不知道就退回「最后一个点号之后」，
        // 两种情况都保证结果**一定**满足「以父 App ID 为前缀」。
        let suffix = if old_main.is_empty() {
            old_id.rsplit('.').next().map(str::to_string)
        } else {
            old_id
                .strip_prefix(&format!("{old_main}."))
                .map(str::to_string)
        }
        .unwrap_or_else(|| "Extension".to_string());
        let new_id = format!("{new_main}.{suffix}");
        d.insert(
            "CFBundleIdentifier".to_string(),
            Value::String(new_id.clone()),
        );

        // Watch 关联键：**只在明确指向旧的主 App ID 时**才修正
        // （自愈路径不知道旧值，而 Watch 扩展的 WKAppBundleIdentifier 指向的是它所属的
        //  Watch App、不是 iOS 主 App，乱改会改坏）。
        if !old_main.is_empty() {
            for key in ["WKAppBundleIdentifier", "WKCompanionAppBundleIdentifier"] {
                let points_to_main = d.get(key).and_then(|v| v.as_string()) == Some(old_main);
                if points_to_main {
                    d.insert(key.to_string(), Value::String(new_main.to_string()));
                }
            }
        }

        let mut out = Vec::new();
        let encoded = if is_binary {
            plist::to_writer_binary(&mut out, &value)
        } else {
            plist::to_writer_xml(&mut out, &value)
        };
        if encoded.is_ok() && fs::write(&p, &out).is_ok() {
            changed += 1;
            let rel = p
                .strip_prefix(app_dir)
                .map(|r| r.display().to_string())
                .unwrap_or_else(|_| p.display().to_string());
            log_msg(&format!("  嵌套扩展 Bundle ID：{rel}：{old_id} → {new_id}"));
        }
    }
    changed
}
