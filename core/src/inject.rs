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
use std::io::Read;
use std::path::{Path, PathBuf};

const MH_MAGIC: u32 = 0xfeed_face;
const MH_MAGIC_64: u32 = 0xfeed_facf;
const MH_CIGAM: u32 = 0xcefa_edfe;
const MH_CIGAM_64: u32 = 0xcffa_edfe;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const FAT_CIGAM: u32 = 0xbeba_feca;
const FAT_CIGAM_64: u32 = 0xbfba_feca;

const LC_SYMTAB: u32 = 0x2;
const LC_DYSYMTAB: u32 = 0xb;
const LC_LOAD_DYLIB: u32 = 0x0c;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const LC_DYLD_INFO_ONLY: u32 = 0x22;
const LC_FUNCTION_STARTS: u32 = 0x26;
const LC_DATA_IN_CODE: u32 = 0x29;
const LC_ENCRYPTION_INFO_64: u32 = 0x2c;
const LC_LINKER_OPTIMIZATION_HINT: u32 = 0x2e;
const LC_DYLD_EXPORTS_TRIE: u32 = 0x33;
const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34;

fn rd_u32(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}
fn wr_u32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_le_bytes());
}

/// 复制 dylib 到 <app>/Frameworks/<name>，并向主二进制插入加载命令。
pub fn inject_dylib(app_dir: &Path, dylib_src: &Path, dylib_name: &str) -> Result<()> {
    // 主可执行文件不再依赖 Info.plist 文本解析（.app 里的 Info.plist 常为二进制 plist，
    // 之前的字符串查找会失败）。改为扫描 .app 根目录里唯一的 Mach-O 文件。
    let exe_path = find_main_executable(app_dir)
        .ok_or_else(|| anyhow::anyhow!("未在 .app 根目录找到主可执行文件（Mach-O）"))?;

    let fw = app_dir.join("Frameworks");
    fs::create_dir_all(&fw)?;
    fs::copy(dylib_src, fw.join(dylib_name))?;

    let load_path = format!("@executable_path/Frameworks/{dylib_name}");

    let mut buf = fs::read(&exe_path)?;
    inject_load_dylib(&mut buf, &load_path)?;
    fs::write(&exe_path, &buf)?;

    let exe_name = exe_path.file_name().and_then(|s| s.to_str()).unwrap_or("?");
    log_msg(&format!("已注入 {load_path} -> {exe_name}"));
    Ok(())
}

/// 扫描 .app 根目录（不递归），返回唯一的 Mach-O（含 fat）可执行文件。
/// 主二进制是根目录里唯一的 Mach-O；Frameworks/PlugIns 均在子目录中。
fn find_main_executable(app_dir: &Path) -> Option<PathBuf> {
    for entry in fs::read_dir(app_dir).ok()?.flatten() {
        let p = entry.path();
        if p.is_dir() {
            continue;
        }
        let mut f = fs::File::open(&p).ok()?;
        let mut magic = [0u8; 4];
        if f.read_exact(&mut magic).is_err() {
            continue;
        }
        let m = u32::from_le_bytes(magic);
        if is_macho(m) || is_fat(m) {
            return Some(p);
        }
    }
    None
}

fn is_macho(m: u32) -> bool {
    matches!(m, MH_MAGIC | MH_MAGIC_64 | MH_CIGAM | MH_CIGAM_64)
}

fn is_fat(m: u32) -> bool {
    matches!(m, FAT_MAGIC | FAT_MAGIC_64 | FAT_CIGAM | FAT_CIGAM_64)
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

    // 修正所有受位移影响的文件偏移（覆盖常见的 offset 型 load command）
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
            LC_CODE_SIGNATURE
            | LC_FUNCTION_STARTS
            | LC_DATA_IN_CODE
            | LC_LINKER_OPTIMIZATION_HINT
            | LC_DYLD_EXPORTS_TRIE
            | LC_DYLD_CHAINED_FIXUPS => {
                // linkedit_data_command：dataoff 在 off+8
                shift_u32_off(buf, off + 8, delta);
            }
            LC_SYMTAB => {
                shift_u32_off(buf, off + 8, delta); // symoff
                shift_u32_off(buf, off + 16, delta); // stroff
            }
            LC_DYSYMTAB => {
                // tocoff/modtaboff/extrefsymoff/indirectsymoff/extreloff/locreloff
                for p in [32usize, 40, 48, 56, 64, 72] {
                    shift_u32_off(buf, off + p, delta);
                }
            }
            LC_ENCRYPTION_INFO_64 => {
                shift_u32_off(buf, off + 8, delta); // cryptoff
            }
            LC_DYLD_INFO_ONLY => {
                // rebase_off/bind_off/weak_bind_off/lazy_bind_off/export_off
                for p in [8usize, 16, 24, 32, 40] {
                    shift_u32_off(buf, off + p, delta);
                }
            }
            _ => {}
        }
        off += cmdsize;
    }
    Ok(())
}

/// 若某 u32 文件偏移非 0，则整体加上 delta（0 表示不存在，不能误加）。
fn shift_u32_off(buf: &mut [u8], p: usize, delta: u64) {
    let old = rd_u32(buf, p) as u64;
    if old != 0 {
        wr_u32(buf, p, (old + delta) as u32);
    }
}
