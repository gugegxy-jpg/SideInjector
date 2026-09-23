//! IPA 解包 / 打包（zip）。

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
    for i in 0..archive.len() {
        let mut zf = archive.by_index(i)?;
        let name = match zf.enclosed_name() {
            Some(n) => n.to_path_buf(),
            None => continue,
        };
        let dest = out.join(&name);
        let unix_mode = zf.unix_mode();
        let is_link = unix_mode.map(is_symlink_mode).unwrap_or(false);

        if zf.is_dir() {
            fs::create_dir_all(&dest)?;
        } else if is_link {
            // 关键：zip 里的符号链接内容是「链接目标路径字符串」，必须还原成真正的 symlink。
            // 否则 `X.framework/Versions/Current` / `X.framework/X` 之类会变成普通文本文件，
            // apple-codesign 遍历 bundle 时会走到不存在的真实文件，报 ENOENT (os error 2)，
            // 表现为「sign error: I/O error: no such file or directory」。
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
        }
    }
    Ok(())
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
