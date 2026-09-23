//! Mach-O 注入：往主二进制插入 LC_LOAD_DYLIB。
//!
//! 原理：被注入的 dylib 利用 `__attribute__((constructor))` 在加载时自动执行，
//! 因此只需新增一条 LC_LOAD_DYLIB 加载命令即可，无需修改符号表/桩（dyld 按名绑定导出）。
//!
//! 支持两种形态：
//!   1. 单切片、小端 64 位 Mach-O（sideload 的 arm64 最常见）；
//!   2. **Fat / 通用二进制**：里面可能同时有 arm64 与 arm64e 两个切片（cputype 相同、
//!      cpusubtype 不同），设备实际运行哪个切片取决于机型，所以**每个 64 位 ARM 切片
//!      都要注入**，注入后按各切片原对齐重新拼装 Fat 容器（并更新 offset/size）。
//! 32 位切片（armv7）不动：现代 iOS 不会执行它，我们的 dylib 也只有 arm64。

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
    // Fat（通用）二进制：可能有 arm64 与 arm64e 两个切片，设备实际跑哪个不确定，
    // 所以每个 64 位 ARM 切片都要注入，最后按原对齐重新拼装容器。
    if is_fat(rd_u32(buf, 0)) {
        return inject_fat(buf, load_path);
    }
    if rd_u32(buf, 0) != MH_MAGIC_64 {
        bail!(
            "不是小端 64 位 Mach-O：magic=0x{:08x}（只支持 arm64 单切片与 Fat/arm64 通用二进制）",
            rd_u32(buf, 0)
        );
    }
    inject_thin(buf, load_path)
}

/// 单个「小端 64 位」Mach-O 切片的注入。
///
/// 两种做法，**优先第一种**：
///
/// 1. **写进加载命令区的空隙**：`sizeofcmds` 末尾到第一个 section 数据之间通常有几千字节
///    填充（`__text` 起点按页对齐），把新 LC **覆盖**在那段填充上即可 —— 只改
///    `ncmds`/`sizeofcmds`，**不移动任何字节**，所有偏移天然保持正确。最稳。
///
/// 2. 空隙不够时才「整体右移」。这时**必须**把所有受影响的偏移都改对，否则 dyld 映射错位，
///    表现就是「安装正常、一启动就闪退」：
///      - 段：整体在插入点之后的移 `fileoff`；**跨插入点的 `__TEXT` 必须保持 `fileoff = 0`**，
///        只把 `filesize` 加上 delta；
///      - 段内每个 section 的 `offset` / `reloff` 也要跟着移（之前漏了这一步）。
fn inject_thin(buf: &mut Vec<u8>, load_path: &str) -> Result<()> {
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

    // ① 首选：写进加载命令区的空隙（覆盖填充字节，不移动任何数据）
    if let Some(gap_end) = first_section_offset(buf, ncmds) {
        if lc_end + lc_size <= gap_end {
            buf[lc_end..lc_end + lc_size].copy_from_slice(&lc);
            wr_u32(buf, 16, ncmds as u32 + 1);
            wr_u32(buf, 20, (sizeofcmds + lc_size) as u32);
            crate::log_detail(&format!(
                "注入：写入加载命令区空隙（{lc_size} 字节，未移动任何数据）"
            ));
            return Ok(());
        }
        crate::log_detail(&format!(
            "注入：加载命令区空隙不足（需要 {lc_size}，只有 {}），改用整体右移",
            gap_end.saturating_sub(lc_end)
        ));
    }

    // ② 兜底：段/数据整体右移 delta
    let tail = buf[lc_end..].to_vec();
    buf.truncate(lc_end);
    buf.extend_from_slice(&lc);
    buf.extend_from_slice(&tail);

    wr_u32(buf, 16, ncmds as u32 + 1);
    wr_u32(buf, 20, sizeofcmds as u32 + lc_size as u32);

    let mut off = hdr_size;
    for _ in 0..ncmds {
        let cmd = rd_u32(buf, off);
        let cmdsize = rd_u32(buf, off + 4) as usize;
        match cmd {
            LC_SEGMENT_64 => {
                // segment_command_64：fileoff(+40,u64) filesize(+48,u64) nsects(+64,u32)
                let fileoff = rd_u64(buf, off + 40);
                if fileoff >= lc_end as u64 {
                    // 整段都在插入点之后：整段后移
                    wr_u64(buf, off + 40, fileoff + delta);
                } else {
                    // 插入点落在这段内部（__TEXT，fileoff = 0）：起点**不动**，只加长度
                    let filesize = rd_u64(buf, off + 48);
                    wr_u64(buf, off + 48, filesize + delta);
                }
                // section_64 数组紧跟在 72 字节的命令头之后，每项 80 字节
                let nsects = rd_u32(buf, off + 64) as usize;
                for i in 0..nsects {
                    let sec = off + 72 + i * 80;
                    if sec + 80 > buf.len() {
                        break;
                    }
                    // section_64：size(+40,u64) offset(+48,u32) reloff(+56,u32)
                    let soff = rd_u32(buf, sec + 48) as u64;
                    if soff >= lc_end as u64 {
                        wr_u32(buf, sec + 48, (soff + delta) as u32);
                    }
                    let reloff = rd_u32(buf, sec + 56) as u64;
                    if reloff != 0 && reloff >= lc_end as u64 {
                        wr_u32(buf, sec + 56, (reloff + delta) as u32);
                    }
                }
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

fn rd_u64(b: &[u8], off: usize) -> u64 {
    let mut v = [0u8; 8];
    v.copy_from_slice(&b[off..off + 8]);
    u64::from_le_bytes(v)
}

fn wr_u64(b: &mut [u8], off: usize, v: u64) {
    b[off..off + 8].copy_from_slice(&v.to_le_bytes());
}

/// 所有 section 里**最小的数据文件偏移**（跳过 0/空 section）——也就是「加载命令区空隙」的
/// 右边界：新 LC 只要放得下，就不需要移动任何字节。
fn first_section_offset(buf: &[u8], ncmds: usize) -> Option<usize> {
    let mut min: Option<usize> = None;
    let mut off = 32usize;
    for _ in 0..ncmds {
        let cmd = rd_u32(buf, off);
        let cmdsize = rd_u32(buf, off + 4) as usize;
        if cmd == LC_SEGMENT_64 {
            let nsects = rd_u32(buf, off + 64) as usize;
            for i in 0..nsects {
                let sec = off + 72 + i * 80;
                if sec + 80 > buf.len() {
                    break;
                }
                let size = rd_u64(buf, sec + 40);
                let soff = rd_u32(buf, sec + 48) as usize;
                if size > 0 && soff > 0 {
                    min = Some(min.map_or(soff, |m: usize| m.min(soff)));
                }
            }
        }
        off += cmdsize;
    }
    min
}

/// 若某 u32 文件偏移非 0，则整体加上 delta（0 表示不存在，不能误加）。
fn shift_u32_off(buf: &mut [u8], p: usize, delta: u64) {
    let old = rd_u32(buf, p) as u64;
    if old != 0 {
        wr_u32(buf, p, (old + delta) as u32);
    }
}

// MARK: - Fat（通用二进制）

/// 64 位 ARM 的 cputype（arm64 与 arm64e 相同，只是 cpusubtype 不同）。
const CPU_TYPE_ARM64: u32 = 0x0100_000c;

fn be_u32(b: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]])
}
fn be_u64(b: &[u8], off: usize) -> u64 {
    let mut v = [0u8; 8];
    v.copy_from_slice(&b[off..off + 8]);
    u64::from_be_bytes(v)
}
fn wr_be_u32(b: &mut [u8], off: usize, v: u32) {
    b[off..off + 4].copy_from_slice(&v.to_be_bytes());
}
fn wr_be_u64(b: &mut [u8], off: usize, v: u64) {
    b[off..off + 8].copy_from_slice(&v.to_be_bytes());
}

/// 向上按 2 的幂对齐。
fn round_up(v: usize, align: usize) -> usize {
    let a = align.max(1);
    (v + a - 1) & !(a - 1)
}

struct FatSlice {
    cputype: u32,
    cpusubtype: u32,
    offset: usize,
    size: usize,
    align: u32,
}

/// 解析 Fat 头（Fat 头本身是大端；小端读 u32 会得到 FAT_CIGAM 系列）。
fn parse_fat(buf: &[u8]) -> Result<(bool, Vec<FatSlice>)> {
    let magic = rd_u32(buf, 0);
    let is64 = magic == FAT_CIGAM_64;
    if magic != FAT_CIGAM && !is64 {
        bail!("Fat 头字节序异常（magic=0x{magic:08x}）");
    }
    let n = be_u32(buf, 4) as usize;
    if n == 0 || n > 64 {
        bail!("Fat 头里的切片数不合理：{n}");
    }
    let entsize = if is64 { 32 } else { 20 };
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let base = 8 + i * entsize;
        if base + entsize > buf.len() {
            bail!("Fat 切片表越界（第 {i} 项）");
        }
        let (offset, size) = if is64 {
            (be_u64(buf, base + 8) as usize, be_u64(buf, base + 16) as usize)
        } else {
            (be_u32(buf, base + 8) as usize, be_u32(buf, base + 12) as usize)
        };
        let align_off = base + if is64 { 24 } else { 16 };
        out.push(FatSlice {
            cputype: be_u32(buf, base),
            cpusubtype: be_u32(buf, base + 4),
            offset,
            size,
            align: be_u32(buf, align_off),
        });
    }
    Ok((is64, out))
}

/// Fat 容器上的注入：解析切片表 → 逐个 64 位 ARM 切片注入 → 按对齐重新拼装并写回新头。
fn inject_fat(buf: &mut Vec<u8>, load_path: &str) -> Result<()> {
    let (is64, slices) = parse_fat(buf)?;

    let targets: Vec<usize> = slices
        .iter()
        .enumerate()
        .filter(|(_, s)| s.cputype == CPU_TYPE_ARM64)
        .map(|(i, _)| i)
        .collect();
    if targets.is_empty() {
        let list: Vec<String> = slices
            .iter()
            .map(|s| format!("0x{:08x}", s.cputype))
            .collect();
        bail!(
            "Fat 二进制里没有 arm64 切片（只有 {}），无法注入",
            list.join(" / ")
        );
    }

    // 把每个切片抠出来（注入只改切片内部偏移，切片之间互不影响）。
    let mut parts: Vec<Vec<u8>> = Vec::with_capacity(slices.len());
    for s in &slices {
        if s.offset + s.size > buf.len() {
            bail!("Fat 切片越界（offset={} size={}）", s.offset, s.size);
        }
        parts.push(buf[s.offset..s.offset + s.size].to_vec());
    }

    for &i in &targets {
        let before = parts[i].len();
        inject_thin(&mut parts[i], load_path).map_err(|e| {
            anyhow::anyhow!(
                "第 {i} 个切片（cputype=0x{:08x}）注入失败：{e:#}",
                slices[i].cputype
            )
        })?;
        crate::log_detail(&format!(
            "注入：Fat 切片 {i}（cputype=0x{:08x}）已注入，{} -> {} 字节",
            slices[i].cputype,
            before,
            parts[i].len()
        ));
    }

    // 重新拼装：按各切片自己的对齐摆好内容，并写回新的 offset/size。
    let entsize = if is64 { 32 } else { 20 };
    let header_len = 8 + slices.len() * entsize;
    let max_shift = slices.iter().map(|s| s.align.min(30)).max().unwrap_or(14);
    let mut out = vec![0u8; round_up(header_len, 1usize << max_shift)];
    for (i, s) in slices.iter().enumerate() {
        let off = round_up(out.len(), 1usize << s.align.min(30));
        out.resize(off, 0);
        out.extend_from_slice(&parts[i]);
        let size = parts[i].len();
        let base = 8 + i * entsize;
        wr_be_u32(&mut out, base, s.cputype);
        wr_be_u32(&mut out, base + 4, s.cpusubtype);
        if is64 {
            wr_be_u64(&mut out, base + 8, off as u64);
            wr_be_u64(&mut out, base + 16, size as u64);
            wr_be_u32(&mut out, base + 24, s.align);
        } else {
            wr_be_u32(&mut out, base + 8, off as u32);
            wr_be_u32(&mut out, base + 12, size as u32);
            wr_be_u32(&mut out, base + 16, s.align);
        }
    }
    wr_be_u32(&mut out, 0, if is64 { FAT_MAGIC_64 } else { FAT_MAGIC });
    wr_be_u32(&mut out, 4, slices.len() as u32);

    crate::log_msg(&format!(
        "注入：Fat 容器已重排（{} 个切片，{} -> {} 字节）",
        slices.len(),
        buf.len(),
        out.len()
    ));
    *buf = out;
    Ok(())
}
