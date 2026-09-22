//! Mach-O 注入：往主二进制插入 LC_LOAD_DYLIB。
//!
//! 原理：被注入的 dylib 利用 `__attribute__((constructor))` 在加载时自动执行，
//! 因此只需新增一条 LC_LOAD_DYLIB 加载命令即可，无需修改符号表/桩（dyld 按名绑定导出）。
//!
//! 范围（spike）：仅处理「单切片、小端 64 位」Mach-O（sideload 的 arm64 常见）。
//! TODO：通用二进制（Fat / arm64e）需先定位目标切片再编辑。

use crate::log_msg;
use anyhow::{bail, Result};
use std::fs;
use std::path::Path;

const MH_MAGIC_64: u32 = 0xfeed_facf;
const LC_SEGMENT_64: u32 = 0x19;
const LC_LOAD_DYLIB: u32 = 0x0c;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const LC_DYLD_INFO_ONLY: u32 = 0x22;

fn rd_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}
fn wr_u32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_le_bytes());
}

/// 复制 dylib 到 <app>/Frameworks/<name>，并向主二进制插入加载命令。
pub fn inject_dylib(app_dir: &Path, dylib_src: &Path, dylib_name: &str) -> Result<()> {
    let info = fs::read(app_dir.join("Info.plist"))?;
    let exe_name = executable_name(&info)
        .ok_or_else(|| anyhow::anyhow!("Info.plist 中未找到 CFBundleExecutable"))?;
    let exe_path = app_dir.join(&exe_name);

    let fw = app_dir.join("Frameworks");
    fs::create_dir_all(&fw)?;
    fs::copy(dylib_src, fw.join(dylib_name))?;

    let load_path = format!("@executable_path/Frameworks/{dylib_name}");

    let mut buf = fs::read(&exe_path)?;
    inject_load_dylib(&mut buf, &load_path)?;
    fs::write(&exe_path, &buf)?;

    log_msg(&format!("已注入 {load_path} -> {exe_name}"));
    Ok(())
}

fn inject_load_dylib(buf: &mut Vec<u8>, load_path: &str) -> Result<()> {
    if rd_u32(buf, 0) != MH_MAGIC_64 {
        bail!("不是小端 64 位 Mach-O（spike 暂不支持 Fat/通用二进制）");
    }
    let ncmds = rd_u32(buf, 16) as usize;
    let sizeofcmds = rd_u32(buf, 20) as usize;
    let hdr_size = 32usize;
    let lc_end = hdr_size + sizeofcmds;

    let name = load_path.as_bytes();
    let name_block = (name.len() + 1 + 7) & !7; // 8 字节对齐
    let lc_size = 24 + name_block; // dylib_command(8) + dylib(16) + name
    let delta = lc_size as u64;

    // 构造新的 LC_LOAD_DYLIB
    let mut lc = vec![0u8; lc_size];
    wr_u32(&mut lc, 0, LC_LOAD_DYLIB);
    wr_u32(&mut lc, 4, lc_size as u32);
    wr_u32(&mut lc, 8, 24); // dylib.name 偏移 = 本条 LC 起点 + 24
    wr_u32(&mut lc, 12, 0); // timestamp
    wr_u32(&mut lc, 16, 0); // current_version
    wr_u32(&mut lc, 20, 0x0001_0000); // compatibility_version = 1.0
    lc[24..24 + name.len()].copy_from_slice(name);
    lc[24 + name.len()] = 0;

    // 把段/数据区整体右移 delta，腾出空间给新 LC
    let tail = buf[lc_end..].to_vec();
    buf.truncate(lc_end);
    buf.extend_from_slice(&lc);
    buf.extend_from_slice(&tail);

    // 更新头部
    wr_u32(buf, 16, ncmds as u32 + 1);
    wr_u32(buf, 20, sizeofcmds as u32 + lc_size as u32);

    // 修正所有受位移影响的文件偏移
    let mut off = hdr_size;
    for _ in 0..ncmds {
        let cmd = rd_u32(buf, off);
        let cmdsize = rd_u32(buf, off + 4) as usize;
        match cmd {
            LC_SEGMENT_64 => {
                // fileoff 在偏移 off+40（u64）
                let p = off + 40;
                let old = u64::from_le_bytes(buf[p..p + 8].try_into().unwrap());
                buf[p..p + 8].copy_from_slice(&(old + delta).to_le_bytes());
            }
            LC_CODE_SIGNATURE => {
                let p = off + 8;
                let old = rd_u32(buf, p) as u64;
                wr_u32(buf, p, (old + delta) as u32);
            }
            LC_DYLD_INFO_ONLY => {
                for f in [8usize, 16, 24, 32, 40] {
                    let p = off + f;
                    let old = rd_u32(buf, p) as u64;
                    if old != 0 {
                        wr_u32(buf, p, (old + delta) as u32);
                    }
                }
            }
            _ => {}
        }
        off += cmdsize;
    }
    Ok(())
}

/// 极简 plist 解析：取 CFBundleExecutable 对应的字符串值。
fn executable_name(plist: &[u8]) -> Option<String> {
    let s = String::from_utf8_lossy(plist);
    let key = "<key>CFBundleExecutable</key>";
    let i = s.find(key)? + key.len();
    let rest = &s[i..];
    let j = rest.find("<string>")? + "<string>".len();
    let end = rest[j..].find("</string>")?;
    Some(rest[j..j + end].to_string())
}
