//! 用导入的开发证书重签整个 .app bundle（进程内库签名）。
//!
//! iOS 禁止 App 通过 fork/exec 启动子进程（spawn 会报 `operation not permitted`），
//! 因此不能把 rcodesign 当外部二进制调用；这里直接链接 apple-codesign 库完成签名。
//!
//! 代码出处（开源署名）：
//!   库依赖：apple-codesign / apple-bundles —— https://github.com/indygreg/apple-platform-rs
//!          许可：MPL-2.0（文件级弱著佐权）。本仓库**未修改其源码**，仅作库链接使用；
//!          分发本 App 时按 MPL-2.0 提供其源码获取地址（crates.io / 上游仓库）即可。
//!   参考实现：下方 `diagnose_bundle` / `classify_bundle` / `report_bundle` 是阅读其
//!          `apple-bundles` 的 `DirectoryBundle` 实现（`shallow` 判定、优先
//!          `Resources/Info.plist`、嵌套 bundle 候选规则）后写成的**镜像检查**，
//!          用于复现它的判定结果、定位它抛出的「不带路径」的 ENOENT。
//!   本文件改动：签名调用链（深签 → 浅签兜底、Entitlements 提取、签出到独立目录
//!          `.si_signed`、失败时报告输出目录进度）均为本项目自有实现。

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

    // 不要用 sign_path_in_place：对「目录型 bundle」它会先把目标文件删掉、再从源路径复制，
    // 而 in-place 时输入与输出是同一个路径 —— 等于删掉源文件后再去 lstat 它，直接 ENOENT。
    // 这里改成签到一个独立输出目录，成功后再整体替换回原 .app（等价于 CLI 的 -o）。
    let parent = app
        .parent()
        .ok_or_else(|| anyhow::anyhow!("无法取得 .app 的父目录：{}", app.display()))?;
    let name = app
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| anyhow::anyhow!("非法的 .app 名称：{}", app.display()))?;

    let out_root = parent.join(".si_signed");
    let _ = fs::remove_dir_all(&out_root);
    fs::create_dir_all(&out_root)
        .with_context(|| format!("创建签名输出目录失败：{}", out_root.display()))?;
    let out = out_root.join(name);

    // ① 先深签：递归重签所有嵌套 bundle（最规范）。
    //    signer 先绑定到局部变量再调用，避免在临时值上链式调用带来的生存期问题。
    let signer = UnifiedSigner::new(settings.clone());
    let result = signer.sign_path(app, &out);
    if let Err(ref e) = result {
        log_msg(&format!("深签失败：{e:#}"));
        if let Some(b) = crate::logbridge::last_bundle() {
            log_msg(&format!("深签失败：最后进入的嵌套 bundle = {b}"));
        }
        // apple-codesign 的 IO 错误不带路径；统计输出目录已产出的内容可推断它走到哪儿。
        report_partial_output(&out_root);

        // ② 回退浅签：不递归进嵌套 bundle，把它们整体原样复制、只重签主 App。
        //    等价于 rcodesign --shallow：第三方 framework 保持原签名，
        //    主 App 的 CodeResources 按原样记录其哈希，iOS 仍能正常校验与运行。
        log_msg("改为浅签重试（不重签嵌套代码，仅重签主 App）…");
        let mut shallow = settings.clone();
        shallow.set_shallow(true);
        let _ = fs::remove_dir_all(&out_root);
        fs::create_dir_all(&out_root)
            .with_context(|| format!("创建签名输出目录失败：{}", out_root.display()))?;
        let signer2 = UnifiedSigner::new(shallow);
        let r2 = signer2.sign_path(app, &out);
        if let Err(ref e2) = r2 {
            log_msg(&format!("浅签也失败：{e2:#}"));
            report_partial_output(&out_root);
        }
        r2.with_context(|| format!("签名 .app 失败（深签与浅签均失败）：{}", app.display()))?;
        log_msg("浅签成功：主 App 已重签，嵌套代码保持原签名");
    }

    // 用签名后的产物替换原 .app
    fs::remove_dir_all(app).with_context(|| format!("移除原 .app 失败：{}", app.display()))?;
    fs::rename(&out, app).with_context(|| format!("替换回 .app 失败：{}", app.display()))?;
    let _ = fs::remove_dir_all(&out_root);

    log_msg("apple-codesign 库签名完成");
    Ok(())
}

/// 签名前诊断：apple-codesign / apple-bundles 抛出的 IO 错误**不带路径**，
/// 这里镜像 apple-bundles 0.21 的 bundle 判定规则，把它「将会看到的结构」打出来：
///
/// - 顶层结构（顶层文件数 + 各子目录及其文件数）——一眼看出目录树是否完整
/// - 主 bundle 与每个「嵌套 bundle 候选目录」的判定结果（类型 / Info.plist 路径 / shallow）
/// - 每个 bundle 依 CFBundleExecutable 解析出的主可执行文件是否存在
///
/// apple-bundles 的判定规则（0.21 源码）：
///   shallow      = 根目录下**没有** Contents 目录
///   info_plist   = 若 `<根>/Resources/Info.plist` 是文件 → 判为 Framework，用它；
///                  否则若 `(<shallow ? 根 : 根/Contents>)/Info.plist` 是文件 → App / Bundle，用它
///   嵌套候选      = 任意子目录（Framework 自身会跳过其 Resources / Versions 两个候选）
/// 它一旦把某目录误判成 bundle，就会按上面这条路径去 `fs::read`，路径不存在即
/// `ENOENT (os error 2)` —— 这正是签名失败的成因，所以每条读路径都在这里验一遍。
fn diagnose_bundle(app: &Path) {
    report_top_level(app);
    report_bundle(app, "主 bundle");
    let mut candidates = 0usize;
    find_bundle_candidates(app, app, &mut candidates, 0);
    log_msg(&format!("bundle 诊断：嵌套 bundle 候选 {candidates} 个"));

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

/// 打印 .app 顶层结构：顶层文件数 + 各子目录（含其文件数）。
/// 若子目录为 0，说明 IPA 是「扁平」的（解压丢了目录层级），apple-codesign 会立刻异常。
fn report_top_level(app: &Path) {
    let Ok(rd) = fs::read_dir(app) else {
        log_msg(&format!("bundle 诊断：无法列出目录 {}", app.display()));
        return;
    };
    let mut dirs: Vec<(String, usize)> = Vec::new();
    let mut top_files = 0usize;
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        match fs::symlink_metadata(&p) {
            Ok(md) if md.is_dir() => dirs.push((name, count_files(&p, 5000))),
            Ok(md) if md.file_type().is_symlink() => dirs.push((format!("{name}[链接]"), 0)),
            _ => top_files += 1,
        }
    }
    dirs.sort();
    log_msg(&format!(
        "bundle 诊断：顶层文件 {top_files} 个；子目录 {} 个：{}",
        dirs.len(),
        dirs.iter()
            .map(|(n, c)| format!("{n}({c})"))
            .collect::<Vec<_>>()
            .join(", ")
    ));
}

/// 递归统计目录内文件数（符号链接按文件计，与 apple-bundles 的 files() 一致）。
fn count_files(dir: &Path, cap: usize) -> usize {
    let mut n = 0usize;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            match fs::symlink_metadata(e.path()) {
                Ok(md) if md.is_dir() => stack.push(e.path()),
                Ok(_) => n += 1,
                Err(_) => {}
            }
            if n >= cap {
                return n;
            }
        }
    }
    n
}

/// 按 apple-bundles 的规则判定目录能否作为 bundle，返回 (类型, Info.plist 路径)。
fn classify_bundle(dir: &Path) -> Option<(&'static str, std::path::PathBuf)> {
    let name = dir.file_name()?.to_string_lossy().to_string();
    let contents = dir.join("Contents");
    let shallow = !contents.is_dir();
    let app_plist = if shallow {
        dir.join("Info.plist")
    } else {
        contents.join("Info.plist")
    };
    let fw_deep = dir.join("Resources").join("Info.plist");
    let fw_shallow = dir.join("Info.plist");
    let fw = if !fw_deep.exists() && name.ends_with(".framework") && fw_shallow.exists() {
        fw_shallow
    } else {
        fw_deep
    };
    if fw.is_file() {
        return Some(("Framework", fw));
    }
    if app_plist.is_file() {
        let t = if name.ends_with(".app") { "App" } else { "Bundle" };
        return Some((t, app_plist));
    }
    None
}

/// 打印某个 bundle 的判定结果与主可执行文件存在性。
fn report_bundle(dir: &Path, tag: &str) {
    let Some((kind, plist)) = classify_bundle(dir) else {
        log_msg(&format!("bundle 诊断：{tag} 不可判定为 bundle"));
        return;
    };
    let contents = dir.join("Contents");
    let shallow = !contents.is_dir();
    let raw = fs::read(&plist).ok();
    let exe = raw
        .as_ref()
        .and_then(|b| plist::from_bytes::<plist::Value>(b).ok())
        .as_ref()
        .and_then(|v| v.as_dictionary())
        .and_then(|d| d.get("CFBundleExecutable"))
        .and_then(|x| x.as_string())
        .unwrap_or("")
        .to_string();
    let exe_path = if shallow {
        dir.join(&exe)
    } else {
        contents.join(&exe)
    };
    log_msg(&format!(
        "bundle 诊断：{tag} 类型={kind} shallow={shallow} Info.plist={} 可读={} 主可执行={} 存在={}",
        plist.display(),
        raw.is_some(),
        if exe.is_empty() { "(无)" } else { exe.as_str() },
        !exe.is_empty() && exe_path.exists()
    ));
    if kind == "Framework" && dir.join("Versions").exists() {
        log_msg(&format!("bundle 诊断：{tag} 含 Versions 目录（会被逐个版本签名）"));
    }
}

/// 枚举所有「能被判定为 bundle」的子目录（命中后不再深入其内部，
/// 与 apple-bundles 的 poisoned_prefixes 行为一致）。
fn find_bundle_candidates(root: &Path, dir: &Path, count: &mut usize, depth: usize) {
    if depth > 8 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut subs: Vec<std::path::PathBuf> = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        if let Ok(md) = fs::symlink_metadata(&p) {
            if md.is_dir() && !md.file_type().is_symlink() {
                subs.push(p);
            }
        }
    }
    subs.sort();
    for p in subs {
        if classify_bundle(&p).is_some() {
            *count += 1;
            let rel = p
                .strip_prefix(root)
                .unwrap_or(&p)
                .to_string_lossy()
                .to_string();
            report_bundle(&p, &format!("嵌套 {rel}"));
            continue;
        }
        find_bundle_candidates(root, &p, count, depth + 1);
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

/// 签名失败后统计输出目录里已产出的内容，并按**写入顺序**（unix ctime）列出最后几个文件。
///
/// apple-codesign 是按 walkdir 排序逐个复制/签名的，所以「最后写入的那个文件」的
/// 后继就是出错点；若一个文件都没产出，说明失败发生在最开始的 bundle 判定阶段
/// （例如某个目录被误判成 bundle、按不存在的路径去读 Info.plist）。
fn report_partial_output(out_root: &Path) {
    let mut entries: Vec<(i64, i64, String, u64)> = Vec::new();
    let mut dirs = 0usize;
    let mut stack = vec![out_root.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            let Ok(md) = fs::symlink_metadata(&p) else { continue };
            if md.is_dir() {
                dirs += 1;
                stack.push(p);
            } else {
                #[cfg(unix)]
                let stamp = {
                    use std::os::unix::fs::MetadataExt;
                    (md.ctime(), md.ctime_nsec())
                };
                #[cfg(not(unix))]
                let stamp = (0i64, 0i64);
                entries.push((stamp.0, stamp.1, p.display().to_string(), md.len()));
            }
        }
    }
    log_msg(&format!(
        "签名中断：输出目录已产出文件 {} 个，子目录 {dirs} 个（{}）",
        entries.len(),
        out_root.display()
    ));
    entries.sort();
    for (_, _, p, n) in entries.iter().rev().take(5) {
        log_msg(&format!("签名中断：最后写入 {p}（{n} 字节）"));
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
