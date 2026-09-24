//! IPA 解包 / 打包（zip）。

use crate::log_msg;
use anyhow::{Context, Result};
use std::fs;
use std::io::{Read, Write};
use std::path::Path;
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

/// zip 条目 unix 模式高位为 S_IFLNK 时表示符号链接。
fn is_symlink_mode(mode: u32) -> bool {
    mode & 0o170000 == 0o120000
}

pub fn unzip(ipa: &Path, out: &Path) -> Result<()> {
    fs::create_dir_all(out).with_context(|| format!("创建输出目录失败：{}", out.display()))?;
    let file = fs::File::open(ipa).with_context(|| format!("打开 IPA 失败：{}", ipa.display()))?;
    let mut archive = ZipArchive::new(file).context("解析 IPA（zip）失败")?;

    let total = archive.len();
    let mut n_files = 0usize;
    let mut n_dirs = 0usize;
    let mut n_links = 0usize;
    let mut n_skipped = 0usize;

    for i in 0..total {
        let mut zf = archive.by_index(i)?;
        let name = match zf.enclosed_name() {
            Some(n) => n.to_path_buf(),
            None => {
                n_skipped += 1;
                if n_skipped <= 20 {
                    log_msg(&format!("unzip: 跳过不安全条目：{}", zf.name()));
                }
                continue;
            }
        };
        let dest = out.join(&name);
        let unix_mode = zf.unix_mode();
        let is_link = unix_mode.map(is_symlink_mode).unwrap_or(false);

        if zf.is_dir() {
            fs::create_dir_all(&dest)?;
            n_dirs += 1;
        } else if is_link {
            // 关键：zip 里的符号链接内容是「链接目标路径字符串」，必须还原成真正的 symlink。
            // 否则 `X.framework/Versions/Current` / `X.framework/X` 之类会变成普通文本文件，
            // apple-codesign 遍历 bundle 时会走到不存在的真实文件，报 ENOENT (os error 2)。
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut target = String::new();
            zf.read_to_string(&mut target)
                .with_context(|| format!("读取符号链接目标失败：{}", name.display()))?;
            let target = target.trim_end_matches(['\r', '\n']).to_string();
            let _ = fs::remove_file(&dest);
            #[cfg(unix)]
            {
                std::os::unix::fs::symlink(&target, &dest)
                    .with_context(|| format!("创建符号链接失败：{} -> {target}", dest.display()))?;
            }
            n_links += 1;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut outf = fs::File::create(&dest)?;
            std::io::copy(&mut zf, &mut outf)?;
            // 只在 zip 明确给出权限时设置，避免 None→0 把文件设成不可读。
            #[cfg(unix)]
            {
                if let Some(m) = unix_mode {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&dest, fs::Permissions::from_mode(m))?;
                }
            }
            n_files += 1;
        }
    }

    log_msg(&format!(
        "unzip: 条目 {total}，文件 {n_files}，目录 {n_dirs}，符号链接 {n_links}，跳过 {n_skipped}"
    ));
    Ok(())
}

/// IPA 自带的关键信息（只读）。
#[derive(Default)]
pub struct IpaInfo {
    /// 主 App 的 `CFBundleIdentifier`。
    pub bundle_id: Option<String>,
    /// 显示名（优先 `CFBundleDisplayName`，退回 `CFBundleName`）。
    pub display_name: Option<String>,
    /// 「扩展 Bundle ID 不以主 App ID 为前缀」的列表 —— 非空表示这个包**自带错配**，不改就装不上。
    pub mismatched_extensions: Vec<String>,
}

/// 从 IPA（zip）里读出主 App 信息：Bundle ID、显示名，以及前缀不符的扩展 ID。
///
/// 只读 `Payload/<X>.app/Info.plist` 与 `Payload/**/*.appex/Info.plist`，**不解包整包、不改任何文件**。
/// 用途：① 首页把「当前值」作为提示展示（而不是填进输入框）；② 判断用户是否真的改过 Bundle ID；
///      ③ 导入时就提示「这个包自带扩展前缀错配」，省掉一次签名与上传（实测白传过 636 MB）。
pub fn ipa_info(ipa: &Path) -> Result<IpaInfo> {
    let file = fs::File::open(ipa).with_context(|| format!("打开 IPA 失败：{}", ipa.display()))?;
    let mut archive = ZipArchive::new(file).context("解析 IPA（zip）失败")?;
    let mut info = IpaInfo::default();
    let mut extension_ids: Vec<String> = Vec::new();

    for i in 0..archive.len() {
        let mut zf = match archive.by_index(i) {
            Ok(z) => z,
            Err(_) => continue,
        };
        let name = zf.name().to_string();
        let Some(rest) = name.strip_prefix("Payload/") else {
            continue;
        };
        // 主 App 只认「Payload/<X>.app/Info.plist」这一层；扩展认任意深度的 *.appex。
        let is_main = rest.ends_with(".app/Info.plist") && rest.matches('/').count() == 1;
        let is_ext = rest.ends_with(".appex/Info.plist");
        if !is_main && !is_ext {
            continue;
        }
        let mut buf = Vec::new();
        if zf.read_to_end(&mut buf).is_err() {
            continue;
        }
        let Ok(value) = plist::from_bytes::<plist::Value>(&buf) else {
            continue;
        };
        let Some(dict) = value.as_dictionary() else {
            continue;
        };
        let get = |k: &str| {
            dict.get(k)
                .and_then(|v| v.as_string())
                .map(|s| s.to_string())
        };
        let Some(id) = get("CFBundleIdentifier") else {
            continue;
        };
        if is_main {
            info.bundle_id = Some(id);
            info.display_name = get("CFBundleDisplayName").or_else(|| get("CFBundleName"));
        } else if dict.get("NSExtension").is_some() || dict.get("WKWatchKitApp").is_some() {
            extension_ids.push(id);
        }
    }

    if let Some(main) = &info.bundle_id {
        let prefix = format!("{main}.");
        info.mismatched_extensions = extension_ids
            .into_iter()
            .filter(|e| !e.starts_with(&prefix))
            .collect();
    }
    Ok(info)
}

/// 从 IPA 里读出主 App 的 `CFBundleIdentifier`。
///
/// 用途：安装前预检 —— 判断设备上是否已存在同 Bundle ID 的 App（覆盖升级时若两者证书不同，
/// installd 会以 `MismatchedApplicationIdentifierEntitlement` 拒绝，而那时整包已经传完了）。
pub fn bundle_id_of_ipa(ipa: &Path) -> Option<String> {
    ipa_info(ipa).ok().and_then(|i| i.bundle_id)
}

pub fn zip_dir(dir: &Path, out: &Path) -> Result<()> {
    if let Some(parent) = out.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = fs::File::create(out)?;
    let mut zw = ZipWriter::new(file);
    let opts = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o755);
    add_dir(&mut zw, dir, dir, opts)?;
    zw.finish()?;
    Ok(())
}

fn add_dir(
    zw: &mut ZipWriter<fs::File>,
    root: &Path,
    dir: &Path,
    opts: SimpleFileOptions,
) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let rel = path.strip_prefix(root).unwrap().to_path_buf();
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        // 用 symlink_metadata，避免把「指向目录的链接」误判成目录递归进去。
        let ft = fs::symlink_metadata(&path)?.file_type();
        if ft.is_symlink() {
            // 重新打包时同样保留符号链接，否则安装后 framework 结构会损坏。
            let target = fs::read_link(&path)?;
            let target_str = target.to_string_lossy().replace('\\', "/");
            let link_opts = opts.unix_permissions(0o120777);
            zw.add_symlink(rel_str, target_str, link_opts)?;
        } else if ft.is_dir() {
            zw.add_directory(format!("{rel_str}/"), opts)?;
            add_dir(zw, root, &path, opts)?;
        } else {
            let data = fs::read(&path)?;
            zw.start_file(rel_str, opts)?;
            zw.write_all(&data)?;
        }
    }
    Ok(())
}
