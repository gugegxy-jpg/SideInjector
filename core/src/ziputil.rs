//! IPA 解包 / 打包（zip）。

use anyhow::Result;
use std::fs;
use std::io::Write;
use std::path::Path;
use zip::{write::SimpleFileOptions, ZipArchive, ZipWriter};

pub fn unzip(ipa: &Path, out: &Path) -> Result<()> {
    fs::create_dir_all(out)?;
    let file = fs::File::open(ipa)?;
    let mut archive = ZipArchive::new(file)?;
    for i in 0..archive.len() {
        let mut zf = archive.by_index(i)?;
        let name = match zf.enclosed_name() {
            Some(n) => n.to_path_buf(),
            None => continue,
        };
        let dest = out.join(&name);
        if zf.is_dir() {
            fs::create_dir_all(&dest)?;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)?;
            }
            let mut outf = fs::File::create(&dest)?;
            std::io::copy(&mut zf, &mut outf)?;
            // 保留可执行权限
            if let Some(mode) = zf.unix_mode() {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    fs::set_permissions(&dest, fs::Permissions::from_mode(mode))?;
                }
                let _ = mode;
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
        if path.is_dir() {
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
